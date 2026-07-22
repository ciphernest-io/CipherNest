/// classifyNetworkError: error-SHAPE classification (never live
/// connectivity probing — a wifi-drop socket error surfaces after
/// reconnect, so probing lies).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/cnest_errors.dart';

void main() {
  test('DNS-class strings map to OfflineError', () {
    const cases = [
      'SocketException: Failed host lookup: www.googleapis.com',
      'SocketException: No address associated with hostname',
      'SocketException: Network is unreachable',
    ];
    for (final c in cases) {
      expect(classifyNetworkError(Exception(c)), isA<OfflineError>(),
          reason: c);
    }
  });

  test('mid-transfer death maps to UploadInterruptedError', () {
    const cases = [
      'ClientException: Connection closed while receiving data',
      'SocketException: Connection reset by peer',
      'SocketException: Broken pipe',
      'SocketException: Software caused connection abort',
      'TimeoutException after 0:05:00.000000',
      'HandshakeException: Connection terminated during handshake',
    ];
    for (final c in cases) {
      expect(
        classifyNetworkError(Exception(c)),
        isA<UploadInterruptedError>(),
        reason: c,
      );
    }
  });

  test('non-network errors return null', () {
    const cases = [
      'FormatException: Unexpected character',
      'StateError: No active cloud account',
      'Exception: Main upload failed',
    ];
    for (final c in cases) {
      expect(classifyNetworkError(Exception(c)), isNull, reason: c);
    }
  });

  test('DNS wins over the interrupted bucket when both match', () {
    // "SocketException: Failed host lookup" contains both 'socketexception'
    // and the DNS needle — must classify as Offline, not Interrupted.
    expect(
      classifyNetworkError(
          Exception('SocketException: Failed host lookup: host')),
      isA<OfflineError>(),
    );
  });
}
