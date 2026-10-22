import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:exif/exif.dart';

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

/// Dimensions AS DISPLAYED: the raw container dimensions with the EXIF
/// orientation applied (orientations 5 to 8 swap width and height). This is
/// what the viewer's hero box, the justified layout and the details sheet
/// want; the raw probe above is what stored a portrait phone photo as
/// landscape and made it balloon on open.
Future<(int, int)?> decodeOrientedImageDims(Uint8List bytes) async {
  final raw = await decodeImageDims(bytes);
  if (raw == null) return null;
  try {
    final tags = await readExifFromBytes(bytes);
    final tag = tags['Image Orientation'];
    final o = tag == null ? 1 : tag.values.firstAsInt();
    if (o >= 5 && o <= 8) return (raw.$2, raw.$1);
  } catch (_) {
    // No EXIF, or unreadable: the raw dimensions stand.
  }
  return raw;
}
