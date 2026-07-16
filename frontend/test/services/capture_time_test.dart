import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/file_metadata_service.dart';

/// The capture-time helper (#1) feeds the upload path, so its failure contract
/// matters: anything without a readable EXIF date must return null (→ the sync
/// layer falls back to the HLC wall) and must NEVER throw. A thrown exception
/// here would abort an otherwise-successful upload.
void main() {
  Uint8List bytesOf(List<int> b) => Uint8List.fromList(b);

  test('garbage bytes yield null, never throw', () async {
    expect(
        await FileMetadataService.captureEpochFromImageBytes(
            bytesOf(List<int>.filled(1024, 0x00))),
        isNull);
  });

  test('empty bytes yield null', () async {
    expect(
        await FileMetadataService.captureEpochFromImageBytes(bytesOf([])),
        isNull);
  });

  test('a JPEG header with no EXIF date yields null', () async {
    // SOI + a stray APP0 marker, no EXIF IFD — the common screenshot case.
    expect(
        await FileMetadataService.captureEpochFromImageBytes(
            bytesOf([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49])),
        isNull);
  });
}
