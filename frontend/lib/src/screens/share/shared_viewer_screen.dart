import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chewie/chewie.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import '../../widgets/theme_icon.dart';
import 'package:video_player/video_player.dart';

import '../../../crypto/aes_gcm.dart';
import '../../../services/encryption_service.dart';

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

  Future<Uint8List> _downloadBlob(String url) async {
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw HttpException('Download failed (${resp.statusCode})');
    }
    // Detect Drive/OneDrive HTML interstitial pages — the share blob would
    // never be HTML, so this means the URL no longer serves the file.
    final ct = resp.headers['content-type'] ?? '';
    if (ct.contains('text/html')) {
      throw const HttpException(
        'Cloud host returned an HTML page instead of the encrypted file. '
        'The share may have been revoked or the link is malformed.',
      );
    }
    return resp.bodyBytes;
  }

  /// Decrypts the share blob. The header layout depends on mode:
  /// - Plain:    [4-byte len = 60] [60-byte wrapped fileKey]
  /// - Password: [4-byte len = 76] [16-byte salt] [60-byte wrapped fileKey]
  /// Body = the original encrypted body, byte-for-byte: single-shot AES-GCM
  /// for images/small files, independent 524,316-byte chunks for videos.
  Future<Uint8List> _decryptShareBlob(
    Uint8List blob,
    SecretKey shareKey,
    bool isPasswordMode,
  ) async {
    if (blob.length < 4) throw const FormatException('Blob too short');
    final headerLen =
        ByteData.sublistView(blob.sublist(0, 4)).getUint32(0, Endian.big);
    final headerEnd = 4 + headerLen;
    if (blob.length < headerEnd) {
      throw const FormatException('Blob too short for declared header');
    }

    final wrappedKey = isPasswordMode
        ? blob.sublist(4 + 16, headerEnd) // skip 16-byte salt
        : blob.sublist(4, headerEnd);

    final cipher = AesGcmCipher();
    final fileKeyBytes = await cipher.decrypt(wrappedKey, shareKey);
    final fileKey = SecretKey(fileKeyBytes);

    final body = blob.sublist(headerEnd);

    // The body layout is ambiguous from length alone: images are encrypted
    // single-shot (one AES-GCM message over the whole body), videos as
    // independent 524,316-byte chunks. A body that fits in one chunk decrypts
    // identically either way, but a single-shot image larger than one chunk
    // MAC-fails if fed through the chunked loop. The web viewer resolves the
    // same ambiguity single-shot-first, which is cheap on native SubtleCrypto;
    // here decryption is pure-Dart on the UI isolate, so try chunked first —
    // its wrong-layout failure costs one ~512 KB chunk MAC check, while a
    // doomed single-shot pass over a large video body stalls for the whole
    // body length before the real decrypt even starts.
    try {
      final out = BytesBuilder(copy: false);
      int offset = 0;
      const encChunk = EncryptionService.encryptedChunkSize;
      while (offset < body.length) {
        final remaining = body.length - offset;
        final size = remaining < encChunk ? remaining : encChunk;
        final chunk = body.sublist(offset, offset + size);
        final plain = await cipher.decrypt(chunk, fileKey);
        out.add(plain);
        offset += size;
      }
      return out.takeBytes();
    } catch (_) {
      // Not a chunked body — a single-shot image larger than one chunk.
      return await cipher.decrypt(body, fileKey);
    }
  }

  Future<File> _writeToTemp(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    // Per-link unique filename so we don't clash with other shares.
    final tag = _downloadUrl.hashCode.toUnsigned(32).toRadixString(16);
    final ext = _extensionForKind(_sniffKind(bytes));
    final path = '${dir.path}/share_$tag$ext';
    final f = File(path);
    await f.writeAsBytes(bytes, flush: true);
    return f;
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
        title: const Text('Shared with you'),
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
          icon: themeIconData('cloudArrowDown'),
          label: 'Downloading encrypted blob…',
          spinner: true,
        );
      case _Phase.decrypting:
        return _StatusView(
          icon: themeIconData('lockKeyOpen'),
          label: 'Decrypting on-device…',
          spinner: true,
        );
      case _Phase.password:
        return _buildPasswordForm(cs);
      case _Phase.expired:
        return _StatusView(
          icon: themeIconData('clockCountdown'),
          label: 'This link has expired.',
          spinner: false,
        );
      case _Phase.error:
        return _StatusView(
          icon: themeIconData('warningCircle'),
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
            Icon(
              themeIconData('lock'),
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
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              themeIconData('musicNotes'),
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
                  icon: Icon(
                    playing
                        ? themeIconData('pauseCircle', selected: true)
                        : themeIconData('playCircle', selected: true),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _mediaKind == _MediaKind.document
                  ? themeIconData('fileText')
                  : themeIconData('file'),
              size: 80,
              color: cs.primary,
            ),
            const SizedBox(height: 16),
            Text(
              f.path.split(Platform.pathSeparator).last,
              style: TextStyle(color: cs.onSurface, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: ThemeIcon('arrowSquareOut'),
              label: const Text('Open with…'),
              onPressed: () async {
                final r = await OpenFile.open(f.path);
                if (r.type != ResultType.done && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Cannot open: ${r.message}')),
                  );
                }
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: ThemeIcon('copy'),
              label: const Text('Copy file path'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: f.path));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Path copied')),
                  );
                }
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
  final IconData icon;
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: cs.primary),
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
