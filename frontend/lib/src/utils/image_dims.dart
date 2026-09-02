import 'dart:typed_data';
import 'dart:ui' as ui;

/// Header-only image dimension probes — no rasterization, no full decode.
/// Raw container dimensions (EXIF rotation NOT applied): callers that can
/// should prefer MediaStore's orientatedWidth/Height; these are the
/// fallback for files with no MediaStore binding.
Future<(int, int)?> decodeImageDims(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return await _dimsOf(buffer);
  } catch (_) {
    return null;
  }
}

Future<(int, int)?> decodeImageDimsFromFile(String path) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    return await _dimsOf(buffer);
  } catch (_) {
    return null;
  }
}

Future<(int, int)?> _dimsOf(ui.ImmutableBuffer buffer) async {
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final dims = descriptor.width > 0 && descriptor.height > 0
      ? (descriptor.width, descriptor.height)
      : null;
  descriptor.dispose();
  buffer.dispose();
  return dims;
}
