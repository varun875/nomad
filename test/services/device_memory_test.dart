import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/device_info_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.varun.nomad/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('memory snapshots are fresh rather than cached', () async {
    var available = 1024;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getMemoryInfo');
      return {'availableBytes': available, 'lowMemory': available == 0};
    });
    expect(await DeviceInfo.memorySnapshot(),
        (availableBytes: 1024, lowMemory: false));
    available = 0;
    expect(await DeviceInfo.memorySnapshot(),
        (availableBytes: 0, lowMemory: true));
  });

  test('unsupported or malformed probes do not invent free RAM', () async {
    messenger.setMockMethodCallHandler(
        channel, (_) async => throw MissingPluginException());
    expect(await DeviceInfo.memorySnapshot(), isNull);
    for (final value in [
      <String, dynamic>{},
      {'availableBytes': -1, 'lowMemory': false},
      {'availableBytes': 1024, 'lowMemory': 'false'},
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => value);
      expect(await DeviceInfo.memorySnapshot(), isNull);
    }
  });
}
