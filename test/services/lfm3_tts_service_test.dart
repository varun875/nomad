import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/lfm3_tts_service.dart';
import 'package:nomad/core/services/speech_input_service.dart';

class _FakeOutput implements SpeechOutput {
  bool initResult = true;
  final initialized = <String>[];
  final spoken = <String>[];
  int stops = 0;

  @override
  Future<bool> initialize({required String localeId}) async {
    initialized.add(localeId);
    return initResult;
  }

  @override
  Future<void> speak(String text, {bool first = false}) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

Uint8List fakeWav() => Uint8List.fromList([82, 73, 70, 70, 1, 2, 3]);

void main() {
  group('Lfm3TtsService', () {
    test('synthesis runs ahead of playback, which stays in order', () async {
      final order = <String>[];
      final gates = <Completer<void>>[];
      final service = Lfm3TtsService(
        initImpl: () async => true,
        synthImpl: (text, voice) async {
          order.add('synth:$voice:$text');
          return fakeWav();
        },
        playImpl: (wav) async {
          final gate = Completer<void>();
          gates.add(gate);
          order.add('play-start:${wav.length}');
          await gate.future;
          order.add('play-end:${wav.length}');
        },
      );
      expect(await service.initialize(localeId: 'en-US'), isTrue);
      final first = service.speak('Hello world.');
      final second = service.speak('Second sentence.');
      // The drain synthesizes the next sentence while the first one is still
      // playing; playback itself never overlaps or reorders.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(order, [
        'synth:female:Hello world.',
        'play-start:7',
        'synth:female:Second sentence.',
      ]);
      gates[0].complete();
      await first;
      expect(order.sublist(3), ['play-end:7', 'play-start:7']);
      gates[1].complete();
      await second;
      expect(order.last, 'play-end:7');
    });

    test('waits while the chat engine is generating', () async {
      var busy = true;
      var synthesized = 0;
      final service = Lfm3TtsService(
        initImpl: () async => true,
        synthImpl: (text, voice) async {
          synthesized++;
          return fakeWav();
        },
        playImpl: (_) async {},
        busyImpl: () => busy,
      );
      await service.initialize(localeId: 'en-US');
      final pending = service.speak('Wait for me.');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(synthesized, 0);
      busy = false;
      await pending;
      expect(synthesized, 1);
    });

    test('falls back when native initialization fails', () async {
      final native = Lfm3TtsService(initImpl: () async => false);
      final system = _FakeOutput();
      final smart = SmartSpeechOutput(native: native, system: system);

      expect(await smart.initialize(localeId: 'en-US'), isTrue);
      await smart.speak('System voice please.');
      expect(system.spoken, ['System voice please.']);
    });

    test('uses native when available', () async {
      final native = Lfm3TtsService(
        initImpl: () async => true,
        synthImpl: (text, voice) async => fakeWav(),
        playImpl: (_) async {},
      );
      final system = _FakeOutput();
      final smart = SmartSpeechOutput(native: native, system: system);

      expect(await smart.initialize(localeId: 'en-US'), isTrue);
      await smart.speak('Native voice please.');
      expect(system.spoken, isEmpty);
    });

    test('stop drops queued sentences', () async {
      var busy = true;
      final service = Lfm3TtsService(
        initImpl: () async => true,
        synthImpl: (text, voice) async => fakeWav(),
        playImpl: (_) async {
          throw StateError('should not play after stop');
        },
        busyImpl: () => busy,
      );
      await service.initialize(localeId: 'en-US');
      final pending = service.speak('Never heard.');
      await service.stop();
      busy = false;
      await pending;
      expect(busy, isFalse);
    });

    test('hybrid opening speaks the first sentence with the system voice',
        () async {
      final synthesized = <String>[];
      final native = Lfm3TtsService(
        initImpl: () async => true,
        synthImpl: (text, voice) async {
          synthesized.add(text);
          return fakeWav();
        },
        playImpl: (_) async {},
      );
      final system = _FakeOutput();
      final smart = SmartSpeechOutput(native: native, system: system);

      expect(await smart.initialize(localeId: 'en-US'), isTrue);
      // The system engine is warmed up front so the opening has somewhere to
      // go while the model is still generating.
      expect(system.initialized, hasLength(1));
      await smart.speak('Opening sentence.', first: true);
      await smart.speak('Native body.');
      expect(system.spoken, ['Opening sentence.']);
      expect(synthesized, ['Native body.']);
    });

    test('hybrid opening falls back to the native voice without system TTS',
        () async {
      final synthesized = <String>[];
      final native = Lfm3TtsService(
        initImpl: () async => true,
        synthImpl: (text, voice) async {
          synthesized.add(text);
          return fakeWav();
        },
        playImpl: (_) async {},
      );
      final system = _FakeOutput()..initResult = false;
      final smart = SmartSpeechOutput(native: native, system: system);

      expect(await smart.initialize(localeId: 'en-US'), isTrue);
      await smart.speak('Opening sentence.', first: true);
      expect(system.spoken, isEmpty);
      expect(synthesized, ['Opening sentence.']);
    });
  });
}
