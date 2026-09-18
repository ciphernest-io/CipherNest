import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import '../database_backup_service.dart';
import '../encryption_service.dart';
import '../../src/models/file_model.dart';
import 'account_registry.dart';
import 'cloud_account.dart';
import 'cloud_provider.dart';
import 'drive_layout.dart';
import 'sealed_metadata.dart';

/// CipherNest OneDrive integration.
/// Uses Microsoft Graph API + OAuth2 (auth code flow) for personal accounts.
class OneDriveProvider implements CloudProvider {
  // ---- IMPORTANT: replace with your Azure AD App's "Application (client) ID" ----
  // Register at https://portal.azure.com -> Microsoft Entra ID -> App registrations.
  // See plan file for exact registration steps.
  static const String _clientId = '6bd09a94-1c3b-4d09-9d35-4a684f285638';
  // HTTPS redirect, NOT a custom scheme. Must stay in sync with two
  // places: the Entra app registration ("Mobile and desktop applications"
  // platform, redirect URI exactly this string) and the `ciphernest`
  // Worker's /oauth-callback page (web-viewer/oauth-callback.html), whose
  // button hands the code back to the app as a ciphernest-open:// intent.
  // Custom-scheme redirects trigger login.live.com's anti-phishing
  // interstitial, which hangs in Custom Tabs (see authenticate() below).
  //
  // Host is a dedicated custom domain on the `ciphernest` Worker that serves
  // ONLY the callback page (worker.js AUTH_HOST), so share-viewer changes can
  // never break sign-in. The old ciphernest.ciphernest20.workers.dev host went
  // dark when custom domains were attached (404 on every path, verified
  // 18 Sep 2026), so it must never come back here.
  static const String _redirectHost = 'auth.ciphernest.io';
  static const String _redirectPath = '/oauth-callback';
  static const String _redirectUri = 'https://$_redirectHost$_redirectPath';
  // /common/ routes any user (personal or work/school) to the right tenant
  // based on their account. /consumers/ would only work for personal-only
  // app registrations, but our app is multi-tenant + personal accounts.
  static const String _authority =
      'https://login.microsoftonline.com/common/oauth2/v2.0';
  static const String _graphBase = 'https://graph.microsoft.com/v1.0';
  // Files.ReadWrite (not .AppFolder): the vault lives in a visible
  // /CipherNest/ tree, matching the Google provider's drive.file posture.
  static const String _scopes =
      'Files.ReadWrite User.Read offline_access';

  /// Path base for a file in the visible tree, e.g.
  /// `/me/drive/root:/CipherNest/vault/<name>`.
  static String _itemPath(String folder, String encodedName) =>
      '$_graphBase/me/drive/root:/${DriveLayout.rootFolder}/$folder/$encodedName';

  /// 32 random bytes, base64url without padding: a 43-char PKCE verifier
  /// (RFC 7636 section 4.1 allows 43..128 chars of the unreserved set).
  static String _newCodeVerifier() {
    final rng = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => rng.nextInt(256)),
    );
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// S256 challenge: base64url(SHA-256(ascii(verifier))), no padding.
  static Future<String> _codeChallengeFor(String verifier) async {
    final hash = await Sha256().hash(ascii.encode(verifier));
    return base64UrlEncode(hash.bytes).replaceAll('=', '');
  }

  @override
  CloudAccount account;

  OneDriveProvider({required this.account});

  // -------------------------------------------------------------------------
  // OAuth — first-time sign-in (static helper, used by cloud-selection screen)
  // -------------------------------------------------------------------------

  /// Performs the OAuth2 authorization-code flow. Opens the system browser,
  /// captures the redirect, exchanges the code for tokens, fetches the
  /// account email. Returns a CloudAccount ready to be registered, or null
  /// if the user cancels.
  static Future<CloudAccount?> signInNewAccount() async {
    // PKCE (RFC 7636). The app is a public client with no secret; the code
    // verifier is what stops anyone who observes the authorization code
    // (the callback tab, a rogue app on the ciphernest-open scheme) from
    // exchanging it. Verifier lives only in this frame and is never logged.
    final codeVerifier = _newCodeVerifier();
    final codeChallenge = await _codeChallengeFor(codeVerifier);

    final authUrl = Uri.parse(
      '$_authority/authorize'
      '?client_id=$_clientId'
      '&response_type=code'
      '&redirect_uri=${Uri.encodeComponent(_redirectUri)}'
      '&response_mode=query'
      '&scope=${Uri.encodeComponent(_scopes)}'
      '&code_challenge=$codeChallenge'
      '&code_challenge_method=S256'
      '&prompt=select_account',
    );

    String redirectResult;
    try {
      // Custom Tabs + HTTPS App Link callback. Four failure modes shaped
      // this configuration — do not "simplify" any of it:
      //  * Embedded WebView (useWebview:true, Jul 5) broke EVERY Microsoft
      //    account: login.live.com stalls post-credential in WebViews,
      //    which Microsoft explicitly discourages for personal accounts.
      //  * Brave's Custom Tab breaks MSA with "Microsoft account is
      //    unavailable from this site" (shields block cross-site storage).
      //  * preferEphemeral makes Brave WORSE (off-the-record tab), stays
      //    false.
      //  * A ciphernest:// custom-scheme redirect triggers login.live.com's
      //    anti-phishing interstitial, and Chrome blocks the scheme
      //    hand-off without a trusted gesture — infinite spinner. The
      //    https App Link redirect skips the interstitial entirely.
      // ONE deterministic delivery path (see CallbackActivity comment in
      // AndroidManifest.xml): Microsoft redirects to the https
      // /oauth-callback page (https redirect_uri = no anti-phishing
      // interstitial), the page renders in the tab, and its button hands
      // the code over as a ciphernest:// intent. The plugin therefore
      // waits on the CUSTOM scheme, always. There is deliberately no
      // https App-Link interception racing this path.
      redirectResult = await FlutterWebAuth2.authenticate(
        url: authUrl.toString(),
        callbackUrlScheme: 'ciphernest',
        options: const FlutterWebAuth2Options(
          preferEphemeral: false,
          customTabsPackageOrder: [
            'com.android.chrome',
            'com.sec.android.app.sbrowser',
          ],
        ),
      );
      debugPrint('OneDrive auth returned redirect: '
          '${redirectResult.split('?').first}?…');
    } catch (e) {
      debugPrint('OneDrive auth cancelled or failed: $e');
      return null;
    }

    final returnedUri = Uri.parse(redirectResult);
    final code = returnedUri.queryParameters['code'];
    if (code == null) {
      debugPrint(
        'OneDrive auth: redirect had no code. '
        'Query params: ${returnedUri.queryParameters.keys.toList()}',
      );
      return null;
    }

    // Exchange the code for tokens
    final tokenResp = await http.post(
      Uri.parse('$_authority/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': _clientId,
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': _redirectUri,
        'code_verifier': codeVerifier,
        'scope': _scopes,
      },
    );

    if (tokenResp.statusCode != 200) {
      throw Exception('Token exchange failed: ${tokenResp.body}');
    }

    final tokenJson = jsonDecode(tokenResp.body) as Map<String, dynamic>;
    final accessToken = tokenJson['access_token'] as String;
    final refreshToken = tokenJson['refresh_token'] as String?;
    final expiresIn = (tokenJson['expires_in'] as num).toInt();
    final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

    // Fetch user email via /me
    final meResp = await http.get(
      Uri.parse('$_graphBase/me'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (meResp.statusCode != 200) {
      throw Exception('Failed to fetch user info: ${meResp.body}');
    }
    final me = jsonDecode(meResp.body) as Map<String, dynamic>;
    final email = (me['mail'] ?? me['userPrincipalName'] ?? '') as String;
    if (email.isEmpty) {
      throw Exception('Could not determine email from Microsoft account');
    }

    return CloudAccount(
      providerType: CloudAccount.providerOneDrive,
      email: email,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
    );
  }

  // -------------------------------------------------------------------------
  // Token management
  // -------------------------------------------------------------------------

  /// Returns a fresh access token, refreshing if needed. Persists rotated
  /// refresh tokens via AccountRegistry.
  Future<String> _getAccessToken() async {
    final current = AccountRegistry().activeAccount ?? account;
    if (!current.isAccessTokenExpired && current.accessToken != null) {
      return current.accessToken!;
    }
    if (current.refreshToken == null) {
      throw Exception('No refresh token available — please sign in again');
    }

    final resp = await http.post(
      Uri.parse('$_authority/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': _clientId,
        'grant_type': 'refresh_token',
        'refresh_token': current.refreshToken!,
        'scope': _scopes,
      },
    );

    if (resp.statusCode != 200) {
      throw Exception('Token refresh failed: ${resp.body}');
    }

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final newAccess = json['access_token'] as String;
    final newRefresh = json['refresh_token'] as String? ?? current.refreshToken;
    final expiresIn = (json['expires_in'] as num).toInt();
    final newExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));

    await AccountRegistry().updateTokens(
      current.id,
      accessToken: newAccess,
      refreshToken: newRefresh,
      expiresAt: newExpiresAt,
    );

    return newAccess;
  }

  Future<Map<String, String>> _authHeaders() async {
    final token = await _getAccessToken();
    return {'Authorization': 'Bearer $token'};
  }

  /// Retries a network call up to 3 times with backoff.
  /// Handles "connection abort" errors that happen when Android kills
  /// in-flight HTTP requests during OAuth browser → app transitions.
  Future<T> _withRetry<T>(Future<T> Function() op) async {
    Object? lastError;
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        return await op();
      } catch (e) {
        lastError = e;
        debugPrint('OneDrive call attempt ${attempt + 1} failed: $e');
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
    }
    throw lastError ?? Exception('Unknown error');
  }

  // -------------------------------------------------------------------------
  // CloudProvider interface
  // -------------------------------------------------------------------------

  @override
  String? get currentUser => account.email;

  @override
  Future<void> signIn() async {
    // Re-validate by refreshing the access token
    await _getAccessToken();
  }

  @override
  Future<void> signOut() async {
    // Microsoft doesn't have a programmatic sign-out per app instance.
    // Just clear local tokens. AccountRegistry.removeAccount handles persistence.
    // The session will be cleared from secure storage by the caller.
  }

  @override
  Future<String?> restoreSession() async {
    try {
      await _getAccessToken();
      return account.email;
    } catch (e) {
      debugPrint('OneDrive restoreSession failed: $e');
      return null;
    }
  }

  // ---- Filename-encoded metadata (OneDrive lacks appProperties) ----

  /// Encodes the HPKE-sealed metadata blob into the cloud filename:
  /// `{stem}.cnest__m__{sealedB64url}`. The base64url alphabet is
  /// filename-safe; the sealed payload's name budget keeps the whole thing
  /// under OneDrive's path-segment ceiling. The plaintext-name legacy format
  /// (`{stem}.cnest__{type}__{b64name}`) is decode-only during the
  /// transition — never written again.
  String _encodeFilename(String stem, String sealedMeta) {
    return '$stem.cnest__m__$sealedMeta';
  }

  /// Parses an encoded filename back into
  /// `(stem, sealed_meta?, type?, original_name?)`.
  /// Returns null if the filename doesn't match any known pattern.
  Map<String, dynamic>? _decodeFilename(String name) {
    const encodedMarker = '.cnest__';
    final idx = name.indexOf(encodedMarker);
    if (idx < 0) {
      // Plain `.cnest` file (e.g. ciphernest_db_backup.cnest) — return defaults
      if (name.endsWith('.cnest')) {
        final stem = name.substring(0, name.length - '.cnest'.length);
        return {'stem': stem};
      }
      return null;
    }
    final stem = name.substring(0, idx);
    final tail = name.substring(idx + encodedMarker.length);

    // Sealed format: m__{sealedB64url}
    if (tail.startsWith('m__')) {
      return {'stem': stem, 'sealed_meta': tail.substring(3)};
    }

    // Legacy plaintext format: {type}__{b64name} — transition-era decode.
    final parts = tail.split('__');
    if (parts.length != 2) return null;
    final type = parts[0];
    String originalName;
    try {
      originalName = utf8.decode(base64Url.decode(parts[1]));
    } catch (_) {
      originalName = parts[1];
    }
    return {'stem': stem, 'type': type, 'original_name': originalName};
  }

  // ---- Upload ----

  static const int _smallUploadThreshold = 4 * 1024 * 1024; // 4 MB

  @override
  Future<String?> uploadEncryptedFile({
    required String filename,
    required CnestFileType type,
    String? originalName,
    Uint8List? fileBytes,
    Stream<List<int>>? fileStream,
    int? fileSize,
  }) async {
    // Strip `.cnest` extension from caller's `filename` to extract the stem
    // (which the rest of the app uses as the local file id).
    final stem = filename.endsWith('.cnest')
        ? filename.substring(0, filename.length - '.cnest'.length)
        : filename;

    // Special files (DB snapshots, both generations) keep their name
    // unencoded and land in backup/; everything else is a vault file in
    // vault/. Vault names carry ONLY the sealed metadata blob — public-key
    // seal, so locked background sync keeps working. If sealing is
    // impossible (no vault key on this device) the name is a bare
    // `{stem}.cnest`; reconcile falls back to the UUID display name.
    final isBackup = DatabaseBackupService.isBackupFile(filename);
    final folder = isBackup ? DriveLayout.backupFolder : DriveLayout.vaultFolder;
    String cloudName;
    if (isBackup) {
      cloudName = filename;
    } else {
      final sealed = await SealedMetadata.seal(
        name: originalName ?? filename,
        type: type,
      );
      cloudName = sealed == null ? '$stem.cnest' : _encodeFilename(stem, sealed);
    }

    // Graph auto-creates missing parent folders on upload; drop the README
    // once the tree exists.
    await _ensureReadme();

    if (fileBytes != null) {
      return _uploadSmall(folder, cloudName, fileBytes);
    }
    if (fileStream != null && fileSize != null) {
      if (fileSize <= _smallUploadThreshold) {
        // Buffer small streams into bytes for the simple PUT path
        final builder = BytesBuilder(copy: false);
        await fileStream.forEach(builder.add);
        return _uploadSmall(folder, cloudName, builder.takeBytes());
      }
      return _uploadLarge(folder, cloudName, fileStream, fileSize);
    }
    throw Exception('No data provided for upload');
  }

  Future<String?> _uploadSmall(
      String folder, String cloudName, Uint8List bytes) async {
    final headers = await _authHeaders();
    final encodedName = Uri.encodeComponent(cloudName);
    final resp = await http.put(
      Uri.parse('${_itemPath(folder, encodedName)}:/content'),
      headers: {
        ...headers,
        'Content-Type': 'application/octet-stream',
      },
      body: bytes,
    );
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw Exception('OneDrive upload failed (${resp.statusCode}): ${resp.body}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return j['id'] as String?;
  }

  Future<String?> _uploadLarge(String folder, String cloudName,
      Stream<List<int>> stream, int totalSize) async {
    final headers = await _authHeaders();
    final encodedName = Uri.encodeComponent(cloudName);

    // Step 1: create upload session
    final createResp = await http.post(
      Uri.parse('${_itemPath(folder, encodedName)}:/createUploadSession'),
      headers: {
        ...headers,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'item': {'@microsoft.graph.conflictBehavior': 'replace'},
      }),
    );
    if (createResp.statusCode != 200) {
      throw Exception('createUploadSession failed: ${createResp.body}');
    }
    final session = jsonDecode(createResp.body) as Map<String, dynamic>;
    final uploadUrl = session['uploadUrl'] as String;

    // Step 2: stream chunks. Spec requires multiples of 320 KiB.
    // Use 10 MiB chunks for efficient throughput.
    const chunkSize = 10 * 1024 * 1024;
    final buffer = BytesBuilder(copy: false);
    int byteOffset = 0;
    String? finalId;

    Future<void> flushChunk(bool isLast) async {
      final chunk = buffer.takeBytes();
      if (chunk.isEmpty && !isLast) return;
      final start = byteOffset;
      final end = byteOffset + chunk.length - 1;
      final resp = await http.put(
        Uri.parse(uploadUrl),
        headers: {
          'Content-Length': '${chunk.length}',
          'Content-Range': 'bytes $start-$end/$totalSize',
        },
        body: chunk,
      );
      byteOffset += chunk.length;
      if (isLast && (resp.statusCode == 200 || resp.statusCode == 201)) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        finalId = j['id'] as String?;
      } else if (resp.statusCode != 202) {
        throw Exception(
            'Chunk upload failed (${resp.statusCode}): ${resp.body}');
      }
    }

    await for (final piece in stream) {
      buffer.add(piece);
      while (buffer.length >= chunkSize) {
        // Carve out exactly chunkSize bytes
        final all = buffer.takeBytes();
        final toSend = all.sublist(0, chunkSize);
        final remainder = all.sublist(chunkSize);
        buffer.add(remainder);
        // Re-buffer the carved-out bytes for flushChunk
        final tempBuffer = BytesBuilder(copy: false);
        tempBuffer.add(toSend);
        // Inline upload of the carved bytes
        final start = byteOffset;
        final end = byteOffset + toSend.length - 1;
        final resp = await http.put(
          Uri.parse(uploadUrl),
          headers: {
            'Content-Length': '${toSend.length}',
            'Content-Range': 'bytes $start-$end/$totalSize',
          },
          body: toSend,
        );
        byteOffset += toSend.length;
        if (resp.statusCode != 202 &&
            resp.statusCode != 200 &&
            resp.statusCode != 201) {
          throw Exception(
              'Chunk upload failed (${resp.statusCode}): ${resp.body}');
        }
        if (resp.statusCode == 200 || resp.statusCode == 201) {
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          finalId = j['id'] as String?;
        }
      }
    }

    // Final tail
    await flushChunk(true);
    return finalId;
  }

  // ---- Download / Delete / List ----

  @override
  Future<Uint8List> downloadFile(String cloudId) async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      final resp = await http.get(
        Uri.parse('$_graphBase/me/drive/items/$cloudId/content'),
        headers: headers,
      );
      if (resp.statusCode != 200 && resp.statusCode != 302) {
        throw Exception('OneDrive download failed (${resp.statusCode})');
      }
      // Parity with the Drive provider: an empty/short body is a
      // still-propagating or transient read, NOT a valid blob (every real
      // vault blob has an 81-byte header + 20-byte preamble at minimum).
      // Throwing here (inside _withRetry) means the caller never caches a
      // 0-byte file — it retries, and the display shows a calm "Syncing…".
      final len = resp.contentLength ?? resp.bodyBytes.length;
      if (resp.bodyBytes.isEmpty || resp.bodyBytes.length < len) {
        throw Exception('OneDrive download incomplete '
            '(${resp.bodyBytes.length}/$len bytes)');
      }
      return resp.bodyBytes;
    });
  }

  @override
  Future<Uint8List> downloadRange(String cloudId, int start, int endInclusive) async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      headers['Range'] = 'bytes=$start-$endInclusive';
      final resp = await http.get(
        Uri.parse('$_graphBase/me/drive/items/$cloudId/content'),
        headers: headers,
      );
      if (resp.statusCode != 206 && resp.statusCode != 200) {
        throw Exception('OneDrive range download failed: ${resp.statusCode}');
      }
      return resp.bodyBytes;
    });
  }

  @override
  Future<void> deleteFile(String cloudId) async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      final resp = await http.delete(
        Uri.parse('$_graphBase/me/drive/items/$cloudId'),
        headers: headers,
      );
      if (resp.statusCode != 204 && resp.statusCode != 404) {
        throw Exception('OneDrive delete failed (${resp.statusCode}): ${resp.body}');
      }
    });
  }

  static String get _logFolderPath =>
      '${DriveLayout.rootFolder}/${DriveLayout.backupFolder}/${DriveLayout.logFolder}';

  @override
  Future<String?> uploadLogObject({
    required String name,
    required Uint8List bytes,
  }) async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      final encodedName = Uri.encodeComponent(name);
      // Graph auto-creates missing parent folders on path-based upload.
      final resp = await http.put(
        Uri.parse(
            '$_graphBase/me/drive/root:/$_logFolderPath/$encodedName:/content'),
        headers: {...headers, 'Content-Type': 'application/octet-stream'},
        body: bytes,
      );
      if (resp.statusCode != 200 && resp.statusCode != 201) {
        throw Exception(
            'OneDrive log upload failed (${resp.statusCode}): ${resp.body}');
      }
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      return j['id'] as String?;
    });
  }

  @override
  Future<List<Map<String, dynamic>>> listLogObjects() async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      final results = <Map<String, dynamic>>[];
      String url =
          '$_graphBase/me/drive/root:/$_logFolderPath:/children?\$top=200&\$select=id,name,size,createdDateTime';
      while (true) {
        final resp = await http.get(Uri.parse(url), headers: headers);
        // No log folder yet = no segments, not an error.
        if (resp.statusCode == 404) return results;
        if (resp.statusCode != 200) {
          throw Exception(
              'OneDrive log list failed (${resp.statusCode}): ${resp.body}');
        }
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        for (final item in (json['value'] as List?) ?? const []) {
          final m = item as Map<String, dynamic>;
          results.add({
            'id': m['id'],
            'name': m['name'],
            'size': m['size'],
            'uploaded': m['createdDateTime'],
          });
        }
        final next = json['@odata.nextLink'] as String?;
        if (next == null) break;
        url = next;
      }
      return results;
    });
  }

  @override
  Future<List<Map<String, dynamic>>> listBackups() async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      final results = <Map<String, dynamic>>[];
      String url =
          '$_graphBase/me/drive/root:/${DriveLayout.rootFolder}/${DriveLayout.backupFolder}:/children?\$top=100&\$select=id,name,size,lastModifiedDateTime';
      while (true) {
        final resp = await http.get(Uri.parse(url), headers: headers);
        // No backup folder yet = no snapshots, not an error.
        if (resp.statusCode == 404) return results;
        if (resp.statusCode != 200) {
          throw Exception(
              'OneDrive backup list failed (${resp.statusCode}): ${resp.body}');
        }
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        for (final item in (json['value'] as List?) ?? const []) {
          final m = item as Map<String, dynamic>;
          results.add({
            'id': m['id'],
            'name': m['name'],
            'size': m['size'],
            'modified': m['lastModifiedDateTime'],
          });
        }
        final next = json['@odata.nextLink'] as String?;
        if (next == null) break;
        url = next;
      }
      return results;
    });
  }

  @override
  Future<void> sealLegacyMetadata({
    required String cloudId,
    required String cloudName,
    required String sealedMeta,
  }) async {
    // OneDrive metadata lives in the filename, so migration is a rename —
    // the blob content is never re-uploaded. The stem (local UUID) must be
    // preserved; only the metadata tail changes.
    final decoded = _decodeFilename(cloudName);
    final stem = decoded?['stem'] as String? ??
        (cloudName.endsWith('.cnest')
            ? cloudName.substring(0, cloudName.length - '.cnest'.length)
            : cloudName);
    return _withRetry(() async {
      final headers = await _authHeaders();
      final resp = await http.patch(
        Uri.parse('$_graphBase/me/drive/items/$cloudId'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'name': _encodeFilename(stem, sealedMeta)}),
      );
      if (resp.statusCode != 200) {
        throw Exception(
            'OneDrive metadata rename failed (${resp.statusCode}): ${resp.body}');
      }
    });
  }

  @override
  Future<List<Map<String, dynamic>>> listCloudFiles() async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      final results = <Map<String, dynamic>>[];
      String url =
          '$_graphBase/me/drive/root:/${DriveLayout.rootFolder}/${DriveLayout.vaultFolder}:/children?\$top=200&\$select=id,name,size,createdDateTime';

      while (true) {
        final resp = await http.get(Uri.parse(url), headers: headers);
        // A fresh OneDrive account has no /CipherNest/vault tree yet (Graph
        // only auto-creates it on first upload), so itemNotFound here means
        // "empty vault", not an error. Without this, the post-sign-in
        // canary and every sync 404s until the first file is uploaded.
        if (resp.statusCode == 404) return results;
        if (resp.statusCode != 200) {
          throw Exception('OneDrive list failed (${resp.statusCode}): ${resp.body}');
        }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = (json['value'] as List?) ?? [];

      for (final item in items) {
        final m = item as Map<String, dynamic>;
        final name = m['name'] as String? ?? '';
        if (!name.contains('.cnest')) continue;

        final decoded = _decodeFilename(name);
        if (decoded == null) continue;

        // Build the same flat shape DatabaseService.reconcile() expects.
        // The "name" field returned must be `{stem}.cnest` (or `_thumb.cnest`)
        // because reconcile parses that pattern to derive the local UUID.
        final stem = decoded['stem'] as String;
        final isThumb = stem.endsWith('_thumb');
        final reconcileName = '$stem.cnest';

        results.add({
          'id': m['id'],
          'name': reconcileName,
          'cloud_name': name, // raw cloud filename — migration renames need it
          'size': m['size'],
          'created': m['createdDateTime'],
          'sealed_meta': decoded['sealed_meta'],
          'type': decoded['type'],
          'original_name': decoded['original_name'],
          if (isThumb) '_isThumb': true,
        });
      }

        final next = json['@odata.nextLink'] as String?;
        if (next == null) break;
        url = next;
      }
      return results;
    });
  }

  @override
  Future<String?> findFileByName(String name) async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      final encodedName = Uri.encodeComponent(name);
      // Only ever called for the DB backup, which lives in backup/.
      final resp = await http.get(
        Uri.parse(_itemPath(DriveLayout.backupFolder, encodedName)),
        headers: headers,
      );
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        return j['id'] as String?;
      }
      return null;
    });
  }

  @override
  Future<bool> checkIntegrity() async {
    // No outer try/catch. Only crypto verification returns `false`; every
    // other failure propagates so the caller can distinguish "wrong key"
    // from "transient network / token / stream error" and retry.
    final list = await listCloudFiles();
    if (list.isEmpty) return true;

    // Find the first non-thumbnail file (thumbnails wouldn't have the
    // master-key-encrypted header structure that verifyKey expects).
    final main = list.firstWhere(
      (f) => f['_isThumb'] != true,
      orElse: () => list.first,
    );
    final fileId = main['id'] as String?;
    if (fileId == null) {
      throw Exception('First cloud file has no id — Graph response malformed');
    }

    final bytes = await downloadFile(fileId);
    // Use just the first chunk for verification
    final probe = bytes.sublist(0, bytes.length < 1024 ? bytes.length : 1024);

    try {
      await EncryptionService.verifyKey(Uint8List.fromList(probe));
      return true;
    } catch (e) {
      debugPrint('OneDrive canary crypto fail (wrong key): $e');
      return false;
    }
  }

  /// Writes the plaintext README into /CipherNest/ once per session. Graph
  /// auto-creates the folder; conflictBehavior 'fail' means an existing
  /// README is left untouched (a 409 is expected and ignored).
  bool _readmeEnsured = false;
  Future<void> _ensureReadme() async {
    if (_readmeEnsured) return;
    _readmeEnsured = true;
    try {
      final headers = await _authHeaders();
      final bytes =
          Uint8List.fromList(DriveLayout.readmeContents.codeUnits);
      final url =
          '$_graphBase/me/drive/root:/${DriveLayout.rootFolder}/${DriveLayout.readmeName}:/content?@microsoft.graph.conflictBehavior=fail';
      await http.put(
        Uri.parse(url),
        headers: {...headers, 'Content-Type': 'text/plain'},
        body: bytes,
      );
    } catch (e) {
      debugPrint('OneDrive README write skipped: $e');
    }
  }

  // ---- PUBLIC SHARE (CipherNest/shares/, anonymous createLink) ----

  @override
  Future<({String cloudId, String downloadUrl})> uploadPublicShare({
    required String filename,
    required Uint8List bytes,
  }) async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      final encodedName = Uri.encodeComponent(filename);

      // 1. Upload to CipherNest/shares/ (small uploads only — share blobs are
      //    typically small images/audio/docs; large videos won't realistically
      //    be shared)
      final uploadResp = await http.put(
        Uri.parse('${_itemPath(DriveLayout.sharesFolder, encodedName)}:/content'),
        headers: {
          ...headers,
          'Content-Type': 'application/octet-stream',
        },
        body: bytes,
      );
      if (uploadResp.statusCode != 200 && uploadResp.statusCode != 201) {
        throw Exception(
            'OneDrive share upload failed (${uploadResp.statusCode}): ${uploadResp.body}');
      }
      final uploaded = jsonDecode(uploadResp.body) as Map<String, dynamic>;
      final cloudId = uploaded['id'] as String;

      // 2. Create anonymous view link
      final linkResp = await http.post(
        Uri.parse('$_graphBase/me/drive/items/$cloudId/createLink'),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'type': 'view', 'scope': 'anonymous'}),
      );
      if (linkResp.statusCode != 200 && linkResp.statusCode != 201) {
        throw Exception(
            'OneDrive createLink failed (${linkResp.statusCode}): ${linkResp.body}');
      }
      final linkJson = jsonDecode(linkResp.body) as Map<String, dynamic>;
      final link = linkJson['link'] as Map<String, dynamic>;
      // The webUrl is the share URL (e.g. https://1drv.ms/...).
      // For direct-binary download we transform it to the OneDrive-recommended
      // pattern by appending '?download=1' — works for anonymous share URLs.
      final shareUrl = link['webUrl'] as String;
      final downloadUrl = '$shareUrl?download=1';
      return (cloudId: cloudId, downloadUrl: downloadUrl);
    });
  }

  @override
  Future<void> deletePublicShare(String cloudId) async {
    try {
      await deleteFile(cloudId);
    } catch (e) {
      debugPrint('deletePublicShare error: $e');
    }
  }
}
