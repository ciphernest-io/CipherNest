import 'dart:io';

/// Write-then-rename so readers polling `exists()` can never observe a
/// half-written cache file (the decrypted-cache read/write race: a reader
/// that catches a partial write strands itself on the thumbnail forever,
/// because nothing retries a "successful" read).
Future<void> atomicWriteBytes(File target, List<int> bytes) async {
  final tmp = File('${target.path}.part');
  await tmp.writeAsBytes(bytes, flush: true);
  try {
    await tmp.rename(target.path);
  } catch (_) {
    // Rename-over-existing can fail on some platforms (Windows tests);
    // fall back to the plain write rather than losing the file.
    try {
      await tmp.delete();
    } catch (_) {}
    await target.writeAsBytes(bytes, flush: true);
  }
}
