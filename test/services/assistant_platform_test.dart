import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/assistant_platform_service.dart';
import 'package:nomad/core/services/speech_input_service.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

Future<void> _event(MethodChannel channel, String method,
    [Object? args]) async {
  final data = await TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall(method, args)),
          null);
  if (data != null) const StandardMethodCodec().decodeEnvelope(data);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const assistantChannel = MethodChannel('com.varun.nomad/assistant');
  const speechChannel = MethodChannel('plugin.csdcorp.com/speech_to_text');

  test(
      'cold and warm invocations are consumed once without depending on app resume',
      () async {
    Map<String, Object>? pending = {'id': 'cold', 'voice': true};
    messenger.setMockMethodCallHandler(assistantChannel, (call) async {
      if (call.method == 'consumeLaunch') {
        final value = pending;
        pending = null;
        return value;
      }
      return null;
    });
    final service =
        AssistantPlatformService(channel: assistantChannel, isAndroid: true);
    final launches = <AssistantLaunch>[];
    final subscription = service.launches.listen(launches.add);
    await service.start();
    await Future<void>.value();
    expect(launches.map((event) => event.id), ['cold']);
    pending = {'id': 'warm', 'voice': true, 'prompt': 'Hello'};
    await _event(assistantChannel, 'assistantInvoked');
    await service.checkPendingLaunch();
    await Future<void>.value();
    expect(launches.map((event) => event.id), ['cold', 'warm']);
    expect(launches.last.prompt, 'Hello');
    pending = {'id': 'warm', 'voice': true};
    await service.checkPendingLaunch();
    await Future<void>.value();
    expect(launches, hasLength(2));
    await subscription.cancel();
    service.dispose();
  });

  test(
      'overlapping launch checks are serialized and retain the next invocation',
      () async {
    final first = Completer<Object?>();
    var calls = 0;
    messenger.setMockMethodCallHandler(assistantChannel, (call) async {
      if (call.method != 'consumeLaunch') return null;
      calls++;
      if (calls == 1) return first.future;
      if (calls == 2) return {'id': 'second', 'voice': false};
      return null;
    });
    final service =
        AssistantPlatformService(channel: assistantChannel, isAndroid: true);
    final launches = <AssistantLaunch>[];
    final subscription = service.launches.listen(launches.add);
    final starting = service.start();
    await Future<void>.value();
    final second = service.checkPendingLaunch();
    final third = service.checkPendingLaunch();
    await Future<void>.value();
    expect(calls, 1);
    first.complete({'id': 'first'});
    await Future.wait([starting, second, third]);
    await Future<void>.value();
    expect(launches.map((event) => event.id), ['first', 'second']);
    expect(launches.last.voice, isFalse);
    await subscription.cancel();
    service.dispose();
  });

  test('speech singleton callbacks are rebound after a previous screen session',
      () async {
    var initializations = 0;
    final nativeCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(speechChannel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'initialize') initializations++;
      return true;
    });
    final input = SystemSpeechInput(speech: SpeechToText.withMethodChannel());
    final oldStatuses = <String>[];
    final newStatuses = <String>[];
    final results = <String>[];
    expect(await input.initialize(), isTrue);
    await input.listen(
        onResult: (_, __) {},
        onStatus: oldStatuses.add,
        onError: (_, __) {},
        onSoundLevel: (_) {},
        localeId: 'en-US');
    await _event(speechChannel, 'notifyStatus', 'listening');
    await input.cancel();
    expect(await input.initialize(), isTrue);
    await input.listen(
        onResult: (text, _) => results.add(text),
        onStatus: newStatuses.add,
        onError: (_, __) {},
        onSoundLevel: (_) {},
        localeId: 'en-IN');
    await _event(speechChannel, 'notifyStatus', 'listening');
    await _event(
        speechChannel,
        'textRecognition',
        jsonEncode(SpeechRecognitionResult.init(
          [const SpeechRecognitionWords('hello again', null, .9)],
          ResultType.finalResult,
        ).toJson()));
    expect(initializations, 1);
    expect(oldStatuses, ['listening']);
    expect(newStatuses, contains('listening'));
    expect(results, ['hello again']);
    final options = nativeCalls
        .lastWhere((call) => call.method == 'listen')
        .arguments as Map;
    expect(options['localeId'], 'en-IN');
    expect(options['listenFor'], 45000);
    await input.cancel();
  });

  test('a denied speech initialization is retried after permission changes',
      () async {
    var granted = false;
    var attempts = 0;
    messenger.setMockMethodCallHandler(speechChannel, (call) async {
      if (call.method == 'initialize') attempts++;
      return granted;
    });
    final input = SystemSpeechInput(speech: SpeechToText.withMethodChannel());
    expect(await input.initialize(), isFalse);
    expect(await input.hasPermission, isFalse);
    granted = true;
    expect(await input.initialize(), isTrue);
    expect(attempts, 2);
    await input.cancel();
  });
}
