import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../../../services/notify.dart';
import '../../widgets/theme_icon.dart';

/// Full-screen in-app capture — the ONLY camera path in a zero-knowledge
/// app (the OEM camera app saves its own plaintext copy to DCIM, which no
/// cleanup can undo). Captures land in app-private temp with a
/// CNEST_yyyyMMdd_HHmmss name and are returned to the caller as a
/// PlatformFile via Navigator.pop; the upload pipeline's finally deletes
/// the plaintext after upload (temp paths fail its isLocalFile test).
class CaptureScreen extends StatefulWidget {
  final bool startInVideoMode;
  const CaptureScreen({super.key, this.startInVideoMode = false});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  late bool _videoMode = widget.startInVideoMode;
  bool _recording = false;
  bool _busy = false;
  FlashMode _flash = FlashMode.off;
  Timer? _recordTimer;
  Duration _recorded = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // v1 is portrait-locked: sensor/EXIF rotation is the plugin's job; a
    // rotating capture UI isn't worth the layout matrix yet.
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.portraitUp]);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations([]);
    _recordTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // Canonical camera-plugin lifecycle: dispose on pause (the OS owns the
  // camera), re-init on resume. A recording in flight is discarded — its
  // partial file dies with the controller.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _recordTimer?.cancel();
      _recording = false;
      _controller = null;
      controller.dispose();
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      if (_cameras.isEmpty) _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        Notify.error('No camera available');
        if (mounted) Navigator.pop(context);
        return;
      }
      _cameraIndex = _cameraIndex.clamp(0, _cameras.length - 1);
      final controller = CameraController(
        _cameras[_cameraIndex],
        ResolutionPreset.high,
        // Audio only in video mode — photo mode must not hold the mic.
        enableAudio: _videoMode,
      );
      await controller.initialize();
      await controller.setFlashMode(_flash);
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      Notify.error('Camera unavailable');
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _recreateController() async {
    final old = _controller;
    setState(() => _controller = null);
    await old?.dispose();
    await _initCamera();
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _busy || _recording) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _recreateController();
  }

  Future<void> _toggleMode() async {
    if (_busy || _recording) return;
    _videoMode = !_videoMode;
    // enableAudio is fixed at construction — mode flips re-create.
    await _recreateController();
  }

  Future<void> _cycleFlash() async {
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      _ => FlashMode.off,
    };
    try {
      await _controller?.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {
      // Some lenses (front) reject flash — leave as-is.
    }
  }

  /// Moves the plugin's capture into our temp dir under a CNEST_* name with
  /// the right extension (the pipeline's video branch keys on it), then
  /// pops with the PlatformFile.
  Future<void> _finishCapture(XFile raw, String extension) async {
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final dir = await getTemporaryDirectory();
    final name = 'CNEST_$stamp.$extension';
    final dest = '${dir.path}/$name';
    await raw.saveTo(dest);
    // saveTo copies — remove the plugin's original so exactly one
    // plaintext copy exists.
    try {
      final orig = File(raw.path);
      if (orig.path != dest && await orig.exists()) await orig.delete();
    } catch (_) {}
    final size = await File(dest).length();
    if (!mounted) return;
    Navigator.pop(
      context,
      PlatformFile(name: name, size: size, path: dest),
    );
  }

  Future<void> _onShutter() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy) {
      return;
    }
    if (!_videoMode) {
      setState(() => _busy = true);
      try {
        final shot = await controller.takePicture();
        await _finishCapture(shot, 'jpg');
      } catch (e) {
        Notify.error('Capture failed');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    // Video: shutter toggles start/stop.
    if (!_recording) {
      try {
        await controller.startVideoRecording();
        _recorded = Duration.zero;
        _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) {
            setState(
                () => _recorded += const Duration(seconds: 1));
          }
        });
        setState(() => _recording = true);
      } catch (e) {
        Notify.error('Could not start recording');
      }
      return;
    }
    setState(() => _busy = true);
    _recordTimer?.cancel();
    try {
      final clip = await controller.stopVideoRecording();
      _recording = false;
      await _finishCapture(clip, 'mp4');
    } catch (e) {
      _recording = false;
      Notify.error('Recording failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _elapsed {
    final m = _recorded.inMinutes.toString().padLeft(2, '0');
    final s = (_recorded.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get _flashIcon => switch (_flash) {
        FlashMode.off => 'flash_off',
        FlashMode.auto => 'flash_auto',
        _ => 'flash_on',
      };

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: controller != null && controller.value.isInitialized
                  ? Center(child: CameraPreview(controller))
                  : const Center(
                      child: CircularProgressIndicator(
                          color: Colors.white70)),
            ),
            // Top bar: close · recording timer · flash · flip.
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    icon: const ThemeIcon('x', color: Colors.white),
                    onPressed:
                        _recording ? null : () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  if (_recording)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.withAlpha(200),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(_elapsed,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ),
                  const Spacer(),
                  IconButton(
                    icon: ThemeIcon(_flashIcon, color: Colors.white),
                    onPressed: _cycleFlash,
                  ),
                  IconButton(
                    icon: const ThemeIcon('cameraswitch',
                        color: Colors.white),
                    onPressed: _flipCamera,
                  ),
                ],
              ),
            ),
            // Bottom bar: mode toggle + shutter.
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_recording)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _ModeChip(
                            label: 'PHOTO',
                            selected: !_videoMode,
                            onTap: _videoMode ? _toggleMode : null),
                        const SizedBox(width: 12),
                        _ModeChip(
                            label: 'VIDEO',
                            selected: _videoMode,
                            onTap: _videoMode ? null : _toggleMode),
                      ],
                    ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: _busy ? null : _onShutter,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: Colors.white, width: 4),
                        color: _videoMode
                            ? (_recording
                                ? Colors.red
                                : Colors.red.withAlpha(180))
                            : Colors.white.withAlpha(60),
                      ),
                      child: _busy
                          ? const Padding(
                              padding: EdgeInsets.all(20),
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2.5),
                            )
                          : _recording
                              ? const Center(
                                  child: ThemeIcon('stop',
                                      color: Colors.white, size: 28))
                              : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  const _ModeChip(
      {required this.label, required this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Colors.white.withAlpha(50) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white60,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}
