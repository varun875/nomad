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
  Future<void> speak(String text) async {
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
    test('speak synthesizes and plays sentences in order', () async {
      final order = <String>[];
      final service = Lfm3TtsService(
        initImpl: () async => true,
        synthImpl: (text, voice) async {
          order.add('synth:$voice:$text');
          return fakeWav();
        },
        playImpl: (wav) async {
          order.add('play:${wav.length}');
        },
      );
      expect(await service.initialize(localeId: 'en-US'), isTrue);
      await service.speak('Hello world.');
      await service.speak('Second sentence.');
      expect(order, [
        'synth:female:Hello world.',
        'play:7',
        'synth:female:Second sentence.',
        'play:7',
      ]);
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
  });
}
