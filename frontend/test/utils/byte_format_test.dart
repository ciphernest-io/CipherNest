/// formatBytes: shared app-wide byte formatter, base-switchable.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ciphernest/src/utils/byte_format.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ByteFormat.setBase(1000);
  });

  test('defaults to 1000 (SI, matches Samsung/Android)', () async {
    SharedPreferences.setMockInitialValues({});
    await ByteFormat.init();
    expect(ByteFormat.base, 1000);
  });

  test('SI base boundaries', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1000), '1.0 KB');
    expect(formatBytes(1023), '1.0 KB');
    expect(formatBytes(999949), '999.9 KB');
    // MB carries two decimals — Samsung Gallery parity ("6.32 MB").
    expect(formatBytes(1000000), '1.00 MB');
    expect(formatBytes(7230000), '7.23 MB');
    expect(formatBytes(6320000), '6.32 MB');
    expect(formatBytes(1000000000), '1.00 GB');
  });

  test('binary base boundaries after switch', () async {
    await ByteFormat.setBase(1024);
    expect(ByteFormat.base, 1024);
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1048576), '1.00 MB');
    expect(formatBytes(7230000), '6.90 MB');
    expect(formatBytes(1073741824), '1.00 GB');
  });

  test('setBase rejects nonsense and persists valid values', () async {
    await ByteFormat.setBase(512);
    expect(ByteFormat.base, 1000); // unchanged
    await ByteFormat.setBase(1024);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(ByteFormat.prefKey), 1024);
    // init() re-reads persisted value.
    await ByteFormat.setBase(1000);
    SharedPreferences.setMockInitialValues({ByteFormat.prefKey: 1024});
    await ByteFormat.init();
    expect(ByteFormat.base, 1024);
  });
}
