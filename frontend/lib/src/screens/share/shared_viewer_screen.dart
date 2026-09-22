import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chewie/chewie.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import '../../widgets/theme_icon.dart';
import 'package:video_player/video_player.dart';

import '../../../crypto/aes_gcm.dart';
import '../../../services/encryption_service.dart';
import '../../../services/notify.dart';

/// Receives a CipherNest magic link (either via the `ciphernest://` custom
/// scheme or an `https://<AppConstants.shareHost>/s/...` App Link) and
/// decrypts the shared blob entirely on-device.
///
/// The route argument is a [Uri] holding the full share URL.
class SharedViewerScreen extends StatefulWidget {
  final Uri shareUri;
  const SharedViewerScreen({super.key, required this.shareUri});

  @override
  State<SharedViewerScreen> createState() => _SharedViewerScreenState();
}

enum _Phase { initial, password, downloading, decrypting, ready, expired, error }

enum _MediaKind { image, video, audio, document, unknown }

class _SharedViewerScreenState extends State<SharedViewerScreen> {
  _Phase _phase = _Phase.initial;
  String? _errorMessage;

  // Parsed link
  late final String _downloadUrl;
  late final bool _hasPassword;
  late final Uint8List? _fragmentKey; // plain mode
  late final Uint8List? _fragmentSalt; // password mode
  late final DateTime? _expiresAt;
  String? _sharedFilename; // from the n= fragment param (sender's filename)

  final _passwordController = TextEditingController();
  bool _passwordSubmitting = false;

  // Decrypted output
  File? _decryptedFile;
  _MediaKind _mediaKind = _MediaKind.unknown;

  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  AudioPlayer? _audioPlayer;

  @override
  void initState() {
    super.initState();
    _parseUri();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _chewieController?.dispose();
    _videoController?.dispose();
    _audioPlayer?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 1. PARSE URL
  // ---------------------------------------------------------------------------

  void _parseUri() {
    try {
      final uri = widget.shareUri;
      // Path is /s/<base64UrlEncodedDownloadUrl>
      final segments = uri.pathSegments;
      if (segments.length < 2 || segments[0] != 's') {
        throw const FormatException('Bad share path');
      }
      _downloadUrl = utf8.decode(base64Url.decode(_padBase64(segments[1])));

      // Fragment carries the key (k=...) or salt (p=...) and expiry (exp=...)
      final fragParams = _parseFragment(uri.fragment);

      final keyB64 = fragParams['k'];
      final saltB64 = fragParams['p'];
      _hasPassword = saltB64 != null;
      _fragmentKey = keyB64 == null ? null : base64Url.decode(_padBase64(keyB64));
      _fragmentSalt = saltB64 == null ? null : base64Url.decode(_padBase64(saltB64));

      final expStr = fragParams['exp'];
      _expiresAt = expStr == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(int.parse(expStr));

      // Original filename travels base64url-encoded in the fragment (n=…),
      // same as the web viewer. Purely cosmetic — a malformed value must
      // never kill the link, so decode failures just drop the name.
      final nameB64 = fragParams['n'];
      if (nameB64 != null) {
        try {
          _sharedFilename =
              utf8.decode(base64Url.decode(_padBase64(nameB64)));
        } catch (_) {
          _sharedFilename = null;
        }
      }

      if (!_hasPassword && _fragmentKey == null) {
        throw const FormatException('Missing key/salt in fragment');
      }

      if (_expiresAt != null && DateTime.now().isAfter(_expiresAt)) {
        setState(() => _phase = _Phase.expired);
        return;
      }

      if (_hasPassword) {
        setState(() => _phase = _Phase.password);
      } else {
        _runPipeline();
      }
    } catch (e) {
      setState(() {
        _phase = _Phase.error;
        _errorMessage = 'Invalid share link: $e';
      });
    }
  }

  String _padBase64(String s) {
    final pad = (4 - s.length % 4) % 4;
    return s + ('=' * pad);
  }

  Map<String, String> _parseFragment(String fragment) {
    final out = <String, String>{};
    for (final part in fragment.split('&')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      out[part.substring(0, eq)] = part.substring(eq + 1);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 2. PIPELINE: download → decrypt → render
  // ---------------------------------------------------------------------------

  Future<void> _runPipeline({String? password}) async {
    setState(() {
      _phase = _Phase.downloading;
      _errorMessage = null;
    });

    try {
      final blob = await _downloadBlob(_downloadUrl);

      if (!mounted) return;
      setState(() => _phase = _Phase.decrypting);

      final shareKey = _hasPassword
          ? await EncryptionService.derivePasswordKey(password!, _fragmentSalt!)
          : SecretKey(_fragmentKey!);

      final decrypted = await _decryptShareBlob(blob, shareKey, _hasPassword);

      if (!mounted) return;
      final out = await _writeToTemp(decrypted);
      _mediaKind = _sniffKind(decrypted);
      _decryptedFile = out;

      if (_mediaKind == _MediaKind.video) await _initVideo(out);
      if (_mediaKind == _MediaKind.audio) await _initAudio(out);

      if (mounted) setState(() => _phase = _Phase.ready);
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _hasPassword ? _Phase.password : _Phase.error;
          _errorMessage = _hasPassword
              ? 'Wrong password or corrupt link.'
              : 'Could not open share: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _passwordSubmitting = false);
    }
  }

  /// Cloud hosts a CipherNest share blob can legitimately live on.
  ///
  /// Kept in step with ALLOWED_HOSTS in worker.js, which enforces the same
  /// list for the browser viewer. The app had no equivalent check, so the
  /// base64 segment of an incoming link was decoded straight into an
  /// http.get: anyone who sent a link could make the app fetch any URL they
  /// chose. Confirmed on a device during MASVS testing, where a crafted link
  /// produced two fetches to a host the tester controlled, identified in the
  /// server log by the app's own Dart user agent (finding F-08).
  ///
  /// Host pinning on the OUTER link is not a substitute. The attacker mints
  /// the outer link, so only the inner URL matters.
  static const Set<String> _allowedDownloadHosts = {
    'drive.google.com',
    'drive.usercontent.google.com',
    'www.googleapis.com',
    'docs.google.com',
    'lh3.googleusercontent.com',
    'onedrive.live.com',
    '1drv.ms',
    'api.onedrive.com',
    'graph.microsoft.com',
  };

  static const List<String> _allowedDownloadSuffixes = ['.sharepoint.com'];

  /// Ceiling on a share body. Without it, `bodyBytes` buffers whatever the
  /// far end sends, so a hostile link was also an out-of-memory kill.
  static const int _maxShareBytes = 512 * 1024 * 1024;

  static bool _isAllowedDownloadHost(Uri uri) {
    if (uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (_allowedDownloadHosts.contains(host)) return true;
    return _allowedDownloadSuffixes.any(host.endsWith);
  }

  /// Redirect hops to follow by hand before giving up.
  static const int _maxRedirects = 10;

  /// Fetches the share blob, following redirects manually and carrying
  /// cookies forward.
  ///
  /// Microsoft's migrated consumer accounts answer the first request with a
  /// redirect chain that sets a session cookie, and serve the bytes only when
  /// that cookie comes back. Automatic redirect following, in Dart's http
  /// helpers and in the Worker alike, drops Set-Cookie between hops, so both
  /// received the HTML interstitial and reported it as a sign-in page. A
  /// browser carried the cookie and saw the file, which is why this looked
  /// for a while like Microsoft blocking anonymous sharing when it never was.
  ///
  /// Following by hand also lets every hop be checked against the allowlist,
  /// which automatic following did not do: previously only the first URL was
  /// validated and a redirect could walk anywhere.
  ///
  /// dart:io rather than package:http because the latter flattens repeated
  /// Set-Cookie headers into one comma-joined string, which cannot be parsed
  /// back reliably (expiry dates contain commas).
  Future<Uint8List> _downloadBlob(String url) async {
    var uri = Uri.parse(url);
    if (!_isAllowedDownloadHost(uri)) {
      throw HttpException(
        'This link points somewhere CipherNest does not recognise '
        '(${uri.host.isEmpty ? uri.scheme : uri.host}). Shares are only ever '
        'hosted on Google Drive or OneDrive, so this link was not made by '
        'CipherNest.',
      );
    }

    final client = HttpClient();
    final jar = <String, String>{};
    try {
      for (var hop = 0; hop <= _maxRedirects; hop++) {
        final req = await client.getUrl(uri);
        req.followRedirects = false;
        if (jar.isNotEmpty) {
          req.headers.set(HttpHeaders.cookieHeader,
              jar.entries.map((e) => '${e.key}=${e.value}').join('; '));
        }
        final res = await req.close();
        for (final c in res.cookies) {
          jar[c.name] = c.value;
        }

        if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
          final loc = res.headers.value(HttpHeaders.locationHeader);
          await res.drain<void>();
          if (loc == null) {
            throw const HttpException('Download failed (redirect with no target)');
          }
          uri = uri.resolve(loc);
          if (!_isAllowedDownloadHost(uri)) {
            throw HttpException(
              'This link redirected to a host CipherNest does not '
              'recognise (${uri.host}).',
            );
          }
          continue;
        }

        if (res.statusCode != 200) {
          await res.drain<void>();
          throw HttpException('Download failed (${res.statusCode})');
        }

        final builder = BytesBuilder(copy: false);
        await for (final chunk in res) {
          builder.add(chunk);
          if (builder.length > _maxShareBytes) {
            throw const HttpException('Shared file is too large to open.');
          }
        }
        final bodyBytes = builder.takeBytes();
        final contentType = res.headers.contentType?.mimeType ?? '';
        return _validateShareBody(bodyBytes, contentType);
      }
      throw const HttpException('Download failed (too many redirects)');
    } finally {
      client.close(force: true);
    }
  }

  /// Rejects the cloud host's HTML interstitial, which is what arrives when a
  /// share has been revoked, has expired, or needs a session we do not have.
  Uint8List _validateShareBody(Uint8List bodyBytes, String contentType) {
    // An HTML body means the cloud served a page rather than the file: the
    // share was revoked, it expired, or the session handshake did not
    // complete. The blob itself is never HTML.
    if (contentType.contains('text/html')) {
      throw const HttpException(
        'Cloud host returned an HTML page instead of the encrypted file. '
        'The share may have been revoked or the link is malformed.',
      );
    }
    // Second gate, independent of what the server claimed the type was:
    // every CipherNest blob opens with the format version byte.
    if (bodyBytes.isEmpty ||
        bodyBytes.first != EncryptionService.formatVersion) {
      throw const HttpException(
        'That did not arrive as a CipherNest file. The share may have been '
        'revoked, or the link may be incomplete.',
      );
    }
    return bodyBytes;
  }

  /// Decrypts the share blob (format v1). Share header:
  /// ```
  /// [1 version=0x01][4 region-len BE][region]
  /// region = password ? (16 salt + 60 wrapped key) : (60 wrapped key)
  /// ```
  /// The body is the vault body byte-for-byte (preamble + AAD-bound chunks),
  /// so [EncryptionService.decryptBody] decrypts it directly — one format,
  /// no ambiguity, full chunk-integrity checks.
  Future<Uint8List> _decryptShareBlob(
    Uint8List blob,
    SecretKey shareKey,
    bool isPasswordMode,
  ) async {
    if (blob.length < 5) throw const FormatException('Blob too short');
    if (blob[0] != EncryptionService.formatVersion) {
      throw FormatException('Unsupported share version ${blob[0]}');
    }
    final regionLen =
        ByteData.sublistView(blob, 1, 5).getUint32(0, Endian.big);
    final regionEnd = 5 + regionLen;
    if (blob.length < regionEnd) {
      throw const FormatException('Blob too short for declared header');
    }

    final wrappedKey = isPasswordMode
        ? blob.sublist(5 + 16, regionEnd) // skip 16-byte salt
        : blob.sublist(5, regionEnd);

    final fileKeyBytes = await AesGcmCipher().decrypt(wrappedKey, shareKey);
    final fileKey = SecretKey(fileKeyBytes);

    return EncryptionService.decryptBody(blob.sublist(regionEnd), fileKey);
  }

  Future<File> _writeToTemp(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    // Per-link unique tag so shares with the same filename don't clash.
    final tag = _downloadUrl.hashCode.toUnsigned(32).toRadixString(16);
    final safeName = _sanitizeFilename(_sharedFilename);
    final ext = _extensionForKind(_sniffKind(bytes));
    // Keep the sender's filename when present — "Open with…" hands the path
    // to external apps, and many key off the name/extension.
    final basename = safeName == null
        ? 'share_$tag$ext'
        : 'share_$tag-$safeName${safeName.contains('.') ? '' : ext}';
    final f = File('${dir.path}/$basename');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  /// Strips path separators and filesystem-hostile characters from an
  /// attacker-controllable fragment value. Returns null if nothing safe
  /// remains, so callers fall back to the sniffed extension.
  String? _sanitizeFilename(String? name) {
    if (name == null) return null;
    var out = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    out = out.replaceAll(RegExp(r'[\x00-\x1F]'), '');
    out = out.replaceAll(RegExp(r'\.{2,}'), '.').trim();
    if (out.isEmpty || out == '.') return null;
    if (out.length > 80) {
      // Preserve the extension when truncating.
      final dot = out.lastIndexOf('.');
      final ext = dot > 0 ? out.substring(dot) : '';
      out = out.substring(0, 80 - ext.length) + ext;
    }
    return out;
  }

  String _extensionForKind(_MediaKind k) {
    switch (k) {
      case _MediaKind.image:
        return '.jpg';
      case _MediaKind.video:
        return '.mp4';
      case _MediaKind.audio:
        return '.m4a';
      case _MediaKind.document:
        return '.pdf';
      case _MediaKind.unknown:
        return '.bin';
    }
  }

  // ---------------------------------------------------------------------------
  // 3. CONTENT-TYPE SNIFFING (magic bytes)
  // ---------------------------------------------------------------------------

  _MediaKind _sniffKind(Uint8List b) {
    if (b.length < 12) return _MediaKind.unknown;
    // JPEG
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return _MediaKind.image;
    // PNG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return _MediaKind.image;
    }
    // GIF
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return _MediaKind.image;
    // WebP — RIFF....WEBP
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return _MediaKind.image;
    }
    // HEIC — ftyp...heic / heix / hevc
    if (b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) {
      final brand = String.fromCharCodes(b.sublist(8, 12));
      if (brand == 'heic' || brand == 'heix' || brand == 'mif1') {
        return _MediaKind.image;
      }
      if (brand == 'isom' ||
          brand == 'mp42' ||
          brand == 'mp41' ||
          brand == 'avc1' ||
          brand == 'iso2') {
        return _MediaKind.video;
      }
    }
    // PDF
    if (b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46) {
      return _MediaKind.document;
    }
    // ID3 / MP3
    if (b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) return _MediaKind.audio;
    if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return _MediaKind.audio;
    // OGG
    if (b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) {
      return _MediaKind.audio;
    }
    // FLAC
    if (b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43) {
      return _MediaKind.audio;
    }
    return _MediaKind.unknown;
  }

  // ---------------------------------------------------------------------------
  // 4. PLAYER INIT
  // ---------------------------------------------------------------------------

  Future<void> _initVideo(File f) async {
    final controller = VideoPlayerController.file(f);
    await controller.initialize();
    _videoController = controller;
    _chewieController = ChewieController(
      videoPlayerController: controller,
      autoPlay: false,
      looping: false,
      aspectRatio: controller.value.aspectRatio,
    );
  }

  Future<void> _initAudio(File f) async {
    _audioPlayer = AudioPlayer();
    await _audioPlayer!.setFilePath(f.path);
  }

  // ---------------------------------------------------------------------------
  // 5. UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _sharedFilename ?? 'Shared with you',
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          icon: ThemeIcon('arrowLeft'),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(child: _buildBody(cs)),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    switch (_phase) {
      case _Phase.initial:
      case _Phase.downloading:
        return _StatusView(
          icon: 'cloudArrowDown',
          label: 'Downloading encrypted blob…',
          spinner: true,
        );
      case _Phase.decrypting:
        return _StatusView(
          icon: 'lockKeyOpen',
          label: 'Decrypting on-device…',
          spinner: true,
        );
      case _Phase.password:
        return _buildPasswordForm(cs);
      case _Phase.expired:
        return _StatusView(
          icon: 'clockCountdown',
          label: 'This link has expired.',
          spinner: false,
        );
      case _Phase.error:
        return _StatusView(
          icon: 'warningCircle',
          label: _errorMessage ?? 'Something went wrong.',
          spinner: false,
        );
      case _Phase.ready:
        return _buildContent(cs);
    }
  }

  Widget _buildPasswordForm(ColorScheme cs) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ThemeIcon(
              'lock',
              size: 56,
              color: cs.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Password required',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'The sender chose to protect this link with a password.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurface.withAlpha(150), fontSize: 13),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _passwordController,
              obscureText: true,
              autofocus: true,
              onSubmitted: (_) => _onPasswordSubmit(),
              decoration: const InputDecoration(
                hintText: 'Password',
                prefixIcon: ThemeIcon('lock'),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: TextStyle(color: cs.error, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _passwordSubmitting ? null : _onPasswordSubmit,
              icon: _passwordSubmitting
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: cs.onPrimary),
                    )
                  : ThemeIcon('lockKeyOpen'),
              label: Text(_passwordSubmitting ? 'Unlocking…' : 'Unlock'),
            ),
          ],
        ),
      ),
    );
  }

  void _onPasswordSubmit() {
    final pwd = _passwordController.text;
    if (pwd.isEmpty) return;
    setState(() => _passwordSubmitting = true);
    _runPipeline(password: pwd);
  }

  Widget _buildContent(ColorScheme cs) {
    final f = _decryptedFile;
    if (f == null) return const SizedBox.shrink();
    switch (_mediaKind) {
      case _MediaKind.image:
        return InteractiveViewer(
          child: Center(child: Image.file(f, fit: BoxFit.contain)),
        );
      case _MediaKind.video:
        if (_chewieController == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Center(child: Chewie(controller: _chewieController!));
      case _MediaKind.audio:
        return _buildAudioPlayer(cs);
      case _MediaKind.document:
      case _MediaKind.unknown:
        return _buildGenericFile(cs, f);
    }
  }

  Widget _buildAudioPlayer(ColorScheme cs) {
    final p = _audioPlayer;
    if (p == null) return const SizedBox.shrink();
    // Scrolls only when the centered column has no room (landscape).
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ThemeIcon(
              'musicNotes',
              size: 80,
              color: cs.primary,
            ),
            const SizedBox(height: 24),
            StreamBuilder<PlayerState>(
              stream: p.playerStateStream,
              builder: (context, snap) {
                final playing = snap.data?.playing ?? false;
                return IconButton(
                  iconSize: 64,
                  onPressed: () => playing ? p.pause() : p.play(),
                  icon: ThemeIcon(
                    playing ? 'pauseCircle' : 'playCircle',
                    selected: true,
                    color: cs.primary,
                  ),
                );
              },
            ),
            StreamBuilder<Duration>(
              stream: p.positionStream,
              builder: (context, snap) {
                final pos = snap.data ?? Duration.zero;
                final total = p.duration ?? Duration.zero;
                return Text(
                  '${_fmt(pos)} / ${_fmt(total)}',
                  style: TextStyle(color: cs.onSurface.withAlpha(180)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildGenericFile(ColorScheme cs, File f) {
    // Scrolls only when the centered column has no room (landscape).
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ThemeIcon(
              _mediaKind == _MediaKind.document ? 'fileText' : 'file',
              size: 80,
              color: cs.primary,
            ),
            const SizedBox(height: 16),
            Text(
              _sharedFilename ?? f.path.split(Platform.pathSeparator).last,
              style: TextStyle(color: cs.onSurface, fontSize: 14),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: ThemeIcon('arrowSquareOut'),
              label: const Text('Open with…'),
              onPressed: () async {
                final r = await OpenFile.open(f.path);
                if (r.type != ResultType.done) {
                  Notify.error('Cannot open: ${r.message}');
                }
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: ThemeIcon('copy'),
              label: const Text('Copy file path'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: f.path));
                Notify.info('Path copied');
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Status view widget — shared by loading / error / expired states
// ---------------------------------------------------------------------------

class _StatusView extends StatelessWidget {
  final String icon;
  final String label;
  final bool spinner;
  const _StatusView({
    required this.icon,
    required this.label,
    required this.spinner,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Scrolls only when the centered column has no room (landscape).
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ThemeIcon(icon, size: 64, color: cs.primary),
            const SizedBox(height: 20),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurface.withAlpha(180)),
            ),
            if (spinner) ...[
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }
}
