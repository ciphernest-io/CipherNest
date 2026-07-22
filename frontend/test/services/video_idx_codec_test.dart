/// The video chunk-index sidecar codec: round-trips, and rejects anything
/// that doesn't validate — a bad idx must mean "don't trust the cache",
/// never a corrupted playback.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/video_streaming_server.dart';

void main() {
  const size = 71000000;
  const total = 140;

  Set<int>? roundTrip(Set<int> chunks) =>
      VideoStreamingServer.decodeChunkIndex(
        VideoStreamingServer.encodeChunkIndex(chunks, size),
        expectedSize: size,
        totalChunks: total,
      );

  test('round-trips contiguous and scattered chunk sets', () {
    expect(roundTrip({0, 1, 2, 3}), {0, 1, 2, 3});
    expect(roundTrip({0, 1, 5, 6, 7, 139}), {0, 1, 5, 6, 7, 139});
    expect(roundTrip(<int>{}), <int>{});
  });

  test('encodes runs compactly', () {
    expect(
      VideoStreamingServer.encodeChunkIndex({0, 1, 2, 9}, size),
      '{"v":1,"size":$size,"chunks":[[0,2],[9,9]]}',
    );
  });

  test('rejects wrong version', () {
    expect(
      VideoStreamingServer.decodeChunkIndex(
        '{"v":2,"size":$size,"chunks":[[0,1]]}',
        expectedSize: size,
        totalChunks: total,
      ),
      isNull,
    );
  });

  test('rejects size mismatch (file content changed)', () {
    expect(
      VideoStreamingServer.decodeChunkIndex(
        '{"v":1,"size":123,"chunks":[[0,1]]}',
        expectedSize: size,
        totalChunks: total,
      ),
      isNull,
    );
  });

  test('rejects out-of-bounds and malformed ranges', () {
    const bad = [
      '{"v":1,"size":71000000,"chunks":[[0,140]]}', // >= totalChunks
      '{"v":1,"size":71000000,"chunks":[[-1,2]]}',
      '{"v":1,"size":71000000,"chunks":[[5,3]]}',
      '{"v":1,"size":71000000,"chunks":[[1]]}',
      '{"v":1,"size":71000000,"chunks":"nope"}',
      'not json at all',
      '{"v":1,"size":71000000}',
    ];
    for (final raw in bad) {
      expect(
        VideoStreamingServer.decodeChunkIndex(raw,
            expectedSize: size, totalChunks: total),
        isNull,
        reason: raw,
      );
    }
  });
}
