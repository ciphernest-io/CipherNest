import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import '../encryption_service.dart';
import '../../src/models/file_model.dart';
import 'account_registry.dart';
import 'cloud_account.dart';
import 'cloud_provider.dart';

/// CipherNest OneDrive integration.
/// Uses Microsoft Graph API + OAuth2 (auth code flow) for personal accounts.
class OneDriveProvider implements CloudProvider {
  // ---- IMPORTANT: replace with your Azure AD App's "Application (client) ID" ----
  // Register at https://portal.azure.com -> Microsoft Entra ID -> App registrations.
  // See plan file for exact registration steps.
  static const String _clientId = '6bd09a94-1c3b-4d09-9d35-4a684f285638';
  static const String _redirectUri = 'ciphernest://oauth-callback';
  // /common/ routes any user (personal or work/school) to the right tenant
  // based on their account. /consumers/ would only work for personal-only
  // app registrations, but our app is multi-tenant + personal accounts.
  static const String _authority =
      'https://login.microsoftonline.com/common/oauth2/v2.0';
  static const String _graphBase = 'https://graph.microsoft.com/v1.0';
  static const String _scopes =
      'Files.ReadWrite.AppFolder User.Read offline_access';

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
    final authUrl = Uri.parse(
      '$_authority/authorize'
      '?client_id=$_clientId'
      '&response_type=code'
      '&redirect_uri=${Uri.encodeComponent(_redirectUri)}'
      '&response_mode=query'
      '&scope=${Uri.encodeComponent(_scopes)}'
      '&prompt=select_account',
    );

    String redirectResult;
    try {
      redirectResult = await FlutterWebAuth2.authenticate(
        url: authUrl.toString(),
        callbackUrlScheme: 'ciphernest',
        options: const FlutterWebAuth2Options(
          preferEphemeral: false,
        ),
      );
    } catch (e) {
      debugPrint('OneDrive auth cancelled or failed: $e');
      return null;
    }

    final returnedUri = Uri.parse(redirectResult);
    final code = returnedUri.queryParameters['code'];
    if (code == null) {
      debugPrint('OneDrive auth: no code in redirect');
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

  /// Encodes type + original_name into the cloud filename so reconcile() can
  /// recover them later. Format: `{stem}__{type}__{b64UrlOriginalName}.cnest`
  /// where `stem` is the file UUID (and possibly `_thumb`) preserved as-is.
  String _encodeFilename(String stem, String type, String originalName) {
    final safeName = base64Url.encode(utf8.encode(originalName));
    return '$stem.cnest__${type}__$safeName';
  }

  /// Parses an encoded filename back into (id, type, originalName).
  /// Returns null if the filename doesn't match the encoded pattern.
  Map<String, dynamic>? _decodeFilename(String name) {
    // Pattern: {stem}.cnest__{type}__{b64name}
    final encodedMarker = '.cnest__';
    final idx = name.indexOf(encodedMarker);
    if (idx < 0) {
      // Plain `.cnest` file (e.g. ciphernest_db_backup.cnest) — return defaults
      if (name.endsWith('.cnest')) {
        final stem = name.substring(0, name.length - '.cnest'.length);
        return {'stem': stem, 'type': null, 'original_name': null};
      }
      return null;
    }
    final stem = name.substring(0, idx);
    final tail = name.substring(idx + encodedMarker.length);
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

    // Special files (DB backup, etc.) keep their original name unencoded.
    final isSpecial = filename == 'ciphernest_db_backup.cnest';
    final cloudName = isSpecial
        ? filename
        : _encodeFilename(stem, type.wireName, originalName ?? filename);

    if (fileBytes != null) {
      return _uploadSmall(cloudName, fileBytes);
    }
    if (fileStream != null && fileSize != null) {
      if (fileSize <= _smallUploadThreshold) {
        // Buffer small streams into bytes for the simple PUT path
        final builder = BytesBuilder(copy: false);
        await fileStream.forEach(builder.add);
        return _uploadSmall(cloudName, builder.takeBytes());
      }
      return _uploadLarge(cloudName, fileStream, fileSize);
    }
    throw Exception('No data provided for upload');
  }

  Future<String?> _uploadSmall(String cloudName, Uint8List bytes) async {
    final headers = await _authHeaders();
    final encodedName = Uri.encodeComponent(cloudName);
    final resp = await http.put(
      Uri.parse(
          '$_graphBase/me/drive/special/approot:/$encodedName:/content'),
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

  Future<String?> _uploadLarge(
      String cloudName, Stream<List<int>> stream, int totalSize) async {
    final headers = await _authHeaders();
    final encodedName = Uri.encodeComponent(cloudName);

    // Step 1: create upload session
    final createResp = await http.post(
      Uri.parse(
          '$_graphBase/me/drive/special/approot:/$encodedName:/createUploadSession'),
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

  @override
  Future<List<Map<String, dynamic>>> listCloudFiles() async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      final results = <Map<String, dynamic>>[];
      String url =
          '$_graphBase/me/drive/special/approot/children?\$top=200&\$select=id,name,size,createdDateTime';

      while (true) {
        final resp = await http.get(Uri.parse(url), headers: headers);
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
          'size': m['size'],
          'created': m['createdDateTime'],
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
      final resp = await http.get(
        Uri.parse('$_graphBase/me/drive/special/approot:/$encodedName'),
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
    try {
      final list = await listCloudFiles();
      if (list.isEmpty) return true;

      // Find the first non-thumbnail file (thumbnails wouldn't have the
      // master-key-encrypted header structure that verifyKey expects).
      final main = list.firstWhere(
        (f) => f['_isThumb'] != true,
        orElse: () => list.first,
      );
      final fileId = main['id'] as String?;
      if (fileId == null) return false;

      final bytes = await downloadFile(fileId);
      // Use just the first chunk for verification
      final probe = bytes.sublist(0, bytes.length < 1024 ? bytes.length : 1024);
      await EncryptionService.verifyKey(Uint8List.fromList(probe));
      return true;
    } catch (e) {
      debugPrint('OneDrive integrity check failed: $e');
      return false;
    }
  }

  // ---- PUBLIC SHARE (uploads to approot, anonymous createLink) ----

  @override
  Future<({String cloudId, String downloadUrl})> uploadPublicShare({
    required String filename,
    required Uint8List bytes,
  }) async {
    return _withRetry(() async {
      final headers = await _authHeaders();
      final encodedName = Uri.encodeComponent(filename);

      // 1. Upload to approot (small uploads only — share blobs are typically
      //    small images/audio/docs; large videos won't realistically be shared)
      final uploadResp = await http.put(
        Uri.parse(
            '$_graphBase/me/drive/special/approot:/$encodedName:/content'),
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
