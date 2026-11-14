import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/assistant_platform_service.dart';
import 'package:nomad/core/services/phone_actions.dart';
import 'package:nomad/core/utils/assistant_command.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.varun.nomad/assistant');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  PhoneActions service() =>
      PhoneActions(AssistantPlatformService(channel: channel, isAndroid: true));

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'typed phone commands reach Android with their parsed arguments',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'success': true, 'message': 'Opening YouTube.'};
      });
      final actions = service();
      final result = await actions.run(AssistantCommand.parse('Open YouTube')!);
      expect(result.success, isTrue);
      expect(result.message, 'Opening YouTube.');
      expect(calls.single.method, 'executeAction');
      expect(calls.single.arguments, {'action': 'openApp', 'name': 'youtube'});
    },
  );

  test('unknown actions are rejected before touching the platform', () async {
    var called = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      called = true;
      return null;
    });
    final result = await service().execute('launchMissiles', {});
    expect(result.success, isFalse);
    expect(called, isFalse);
  });

  test('a channel failure is reported without claiming success', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'error', message: 'No dialer installed.');
    });
    final result = await service().execute('call', {'number': '5551234567'});
    expect(result.success, isFalse);
    expect(result.message, 'No dialer installed.');
  });

  test(
    'the phone_action tool forwards model arguments as device args',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {
          'success': true,
          'message': 'Opening Clock with your timer request.',
        };
      });
      final output = await service().tool.invoke({
        'action': 'timer',
        'seconds': 600,
        'name': '',
      });
      expect(output, 'Opening Clock with your timer request.');
      expect(calls.single.arguments, {'action': 'timer', 'seconds': 600});
    },
  );
}
