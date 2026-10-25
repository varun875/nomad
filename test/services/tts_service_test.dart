import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:nomad/core/services/tts_service.dart';

class _Engine extends Fake implements FlutterTts {
  final languages = <String>[];
  final utterances = <String>[];
  final results = <Completer<dynamic>>[];
  List<Map<String, Object>> voices = [];
  Map<String, String>? selectedVoice;
  Completer<dynamic>? initializeGate;
  Completer<dynamic>? stopGate;
  int stops = 0;
  bool failedLanguage = false;
  bool awaitCompletion = false;
  ErrorHandler? nativeError;
  VoidCallback? nativeCancel;

  @override
  void setErrorHandler(ErrorHandler handler) => nativeError = handler;
  @override
  void setCancelHandler(VoidCallback callback) => nativeCancel = callback;

  @override
  Future<dynamic> awaitSpeakCompletion(bool value) async {
    awaitCompletion = value;
    return initializeGate == null ? 1 : await initializeGate!.future;
  }

  @override
  Future<dynamic> setLanguage(String language) async {
    languages.add(language);
    return failedLanguage ? 0 : 1;
  }

  @override
  Future<dynamic> setVolume(double volume) async => 1;
  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;
  @override
  Future<dynamic> setPitch(double pitch) async => 1;
  @override
  Future<dynamic> get getVoices async => voices;
  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    selectedVoice = voice;
    return 1;
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) {
    expectSync(focus, isFalse);
    utterances.add(text);
    final result = Completer<dynamic>();
    results.add(result);
    return result.future;
  }

  @override
  Future<dynamic> stop() async {
    stops++;
    return stopGate == null ? 1 : await stopGate!.future;
  }
}

void main() {
  testWidgets(
      'selects an installed local voice matching the recognition locale',
      (tester) async {
    final engine = _Engine()
      ..voices = [
        {'name': 'US local', 'locale': 'en-US', 'quality': '500'},
        {
          'name': 'IN neural',
          'locale': 'en-IN',
          'quality': 'very_high',
          'network_required': '1'
        },
        {
          'name': 'IN local',
          'locale': 'en-IN',
          'quality': 'high',
          'network_required': '0'
        },
      ];
    final tts = TtsService(engine: engine);
    expect(await tts.initialize(localeId: 'en_IN'), isTrue);
    expect(engine.awaitCompletion, isTrue);
    expect(engine.languages, ['en-IN']);
    expect(engine.selectedVoice?['name'], 'IN local');
    expect(engine.utterances, isEmpty);
  });

  testWidgets(
      'speak waits for native completion; old completions cannot finish a new utterance',
      (tester) async {
    final engine = _Engine();
    final tts = TtsService(engine: engine);
    await tts.initialize(localeId: 'en-US');
    var firstDone = false;
    final first = tts.speak('First.').then((_) => firstDone = true);
    await tester.pump();
    expect(firstDone, isFalse);
    await tts.stop();
    await first;
    var secondDone = false;
    final second = tts.speak('Second.').then((_) => secondDone = true);
    await tester.pump();
    engine.results.first.complete(1);
    await tester.pump();
    expect(secondDone, isFalse);
    engine.results.last.complete(1);
    await second;
    expect(secondDone, isTrue);
  });

  testWidgets('a new utterance cannot race an unfinished stop', (tester) async {
    final engine = _Engine();
    final tts = TtsService(engine: engine);
    await tts.initialize(localeId: 'en-US');
    engine.stopGate = Completer<dynamic>();
    final stopping = tts.stop();
    final speaking = tts.speak('After stop.');
    await tester.pump();
    expect(engine.utterances, isEmpty);
    engine.stopGate!.complete(1);
    await stopping;
    await tester.pump();
    expect(engine.utterances, ['After stop.']);
    engine.results.single.complete(1);
    await speaking;
  });

  testWidgets('playback failures are surfaced and reinitialize on retry',
      (tester) async {
    final engine = _Engine();
    final tts = TtsService(engine: engine);
    await tts.initialize(localeId: 'en-US');
    final failed = expectLater(tts.speak('A failed reply.'), throwsStateError);
    await tester.pump();
    engine.results.single.complete(0);
    await failed;
    expect(await tts.initialize(localeId: 'en-US'), isTrue);
    expect(engine.languages, hasLength(2));
  });

  testWidgets('a hung playback is stopped instead of waiting forever',
      (tester) async {
    final engine = _Engine();
    final tts = TtsService(
        engine: engine, utteranceTimeout: const Duration(seconds: 1));
    await tts.initialize(localeId: 'en-US');
    final failed = expectLater(tts.speak('No completion.'), throwsStateError);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await failed;
    expect(engine.stops, 1);
  });

  testWidgets(
      'native error callbacks release a speak Future that never completes',
      (tester) async {
    final engine = _Engine();
    final tts = TtsService(engine: engine);
    await tts.initialize(localeId: 'en-US');
    final failed =
        expectLater(tts.speak('Broken synthesis.'), throwsStateError);
    await tester.pump();
    engine.nativeError!('synthesis error');
    await tester.pump();
    await failed;
    expect(engine.stops, 1);
    engine.results.single.complete(0);
    await tester.pump();
  });

  testWidgets('failed or hung initialization does not poison the next attempt',
      (tester) async {
    final engine = _Engine()..initializeGate = Completer<dynamic>();
    final tts = TtsService(
        engine: engine, initializationTimeout: const Duration(seconds: 1));
    final oldGate = engine.initializeGate!;
    final timedOut = tts.initialize(localeId: 'en-US');
    await tester.pump(const Duration(seconds: 2));
    expect(await timedOut, isFalse);
    engine.initializeGate = null;
    expect(await tts.initialize(localeId: 'fr-FR'), isTrue);
    oldGate.complete(1);
    await tester.pump();
    expect(engine.languages, ['fr-FR']);
  });
}
