import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'speech_input_service.dart';

/// One utterance at a time, owned by the voice session. Native speak futures
/// carry completion; unscoped onComplete callbacks cannot finish a newer turn.
class TtsService implements SpeechOutput {
  TtsService(
      {FlutterTts? engine,
      this.utteranceTimeout = const Duration(seconds: 90),
      this.initializationTimeout = const Duration(seconds: 10)})
      : _engine = engine;

  FlutterTts? _engine;
  final Duration utteranceTimeout;
  final Duration initializationTimeout;
  Future<bool>? _initializing;
  Future<void> _stopping = Future.value();
  Completer<void>? _cancelled;
  Completer<void>? _speechError;
  String? _locale;
  bool _ready = false;
  int _generation = 0;
  int _configuration = 0;

  @override
  Future<bool> initialize({required String localeId}) async {
    final locale = localeId.replaceAll('_', '-');
    if (_ready && locale == _locale) return true;
    final inProgress = _initializing;
    if (inProgress != null) {
      await inProgress;
      if (_ready && locale == _locale) return true;
    }
    final configuration = ++_configuration;
    final operation = _configure(locale, configuration)
        .timeout(initializationTimeout, onTimeout: () {
      if (_configuration == configuration) {
        ++_configuration;
        _ready = false;
      }
      return false;
    });
    _initializing = operation;
    try {
      return await operation;
    } finally {
      if (identical(_initializing, operation)) _initializing = null;
    }
  }

  Future<bool> _configure(String locale, int configuration) async {
    _ready = false;
    try {
      final tts = _engine ??= FlutterTts();
      // Android reports some engine errors only through this callback, leaving
      // its speak Future pending. Fail that utterance instead of waiting 90s.
      void reportFailure(Object message) {
        final failed = _speechError;
        if (failed != null && !failed.isCompleted) {
          failed.completeError(StateError('Speech playback failed: $message'));
        }
      }

      tts.setErrorHandler(
          (message) => reportFailure(message ?? 'speech engine error'));
      tts.setCancelHandler(() => reportFailure('speech was interrupted'));
      await tts.awaitSpeakCompletion(true);
      if (_configuration != configuration) return false;
      final language = await tts.setLanguage(locale);
      if (_configuration != configuration ||
          language == false ||
          language == 0) {
        return false;
      }
      await tts.setVolume(1.0); // Utterance gain, never the device's volume.
      await tts.setSpeechRate(Platform.isIOS || Platform.isMacOS ? 0.52 : 0.48);
      await tts.setPitch(1.0);
      if (Platform.isIOS) {
        await tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playAndRecord,
          [
            IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
            IosTextToSpeechAudioCategoryOptions.allowBluetooth,
            IosTextToSpeechAudioCategoryOptions.duckOthers,
          ],
          IosTextToSpeechAudioMode.voicePrompt,
        );
      }
      if (_configuration != configuration) return false;
      await _selectVoice(tts, locale, configuration);
      if (_configuration != configuration) return false;
      _locale = locale;
      _ready = true;
      return true;
    } catch (error) {
      debugPrint('Could not initialize spoken replies: $error');
      return false;
    }
  }

  Future<void> _selectVoice(
      FlutterTts tts, String locale, int configuration) async {
    try {
      final raw = await tts.getVoices;
      if (raw is! List || _configuration != configuration) return;
      final target = locale.toLowerCase();
      final language = target.split('-').first;
      final voices =
          raw.whereType<Map>().map(Map<String, dynamic>.from).where((voice) {
        final id =
            '${voice['locale'] ?? ''}'.replaceAll('_', '-').toLowerCase();
        final network = '${voice['network_required']}'.toLowerCase();
        final features = '${voice['features'] ?? ''}'.toLowerCase();
        return id.split('-').first == language &&
            network != 'true' &&
            network != '1' &&
            !features.contains('notinstalled') &&
            !'${voice['name']}'.toLowerCase().contains('network') &&
            voice['notInstalled'] != true &&
            voice['notInstalled'] != 'true';
      }).toList();
      int score(Map<String, dynamic> voice) {
        final id = '${voice['locale']}'.replaceAll('_', '-').toLowerCase();
        final name = '${voice['name']}'.toLowerCase();
        final quality = '${voice['quality']}'.toLowerCase();
        const qualities = {
          'very_high': 500,
          'high': 400,
          'normal': 300,
          'low': 200,
          'very_low': 100
        };
        return (id == target ? 1000 : 0) +
            (int.tryParse(quality) ?? qualities[quality] ?? 0) +
            (name.contains('enhanced') || name.contains('premium') ? 100 : 0);
      }

      voices.sort((a, b) => score(b).compareTo(score(a)));
      if (voices.isNotEmpty) {
        await tts.setVoice({
          'name': '${voices.first['name']}',
          'locale': '${voices.first['locale']}',
        });
      }
    } catch (_) {
      // Voice enumeration is optional; retain the engine's locale default.
    }
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (!_ready) throw StateError('Spoken replies are not available.');
    final generation = _generation;
    await _stopping;
    if (generation != _generation) return;
    final cancelled = Completer<void>();
    final failed = Completer<void>();
    _cancelled = cancelled;
    _speechError = failed;
    try {
      // Android focus is held by the whole voice session. Asking the TTS plugin
      // for separate focus on each sentence would interrupt that same session.
      final playback = _engine!.speak(text).then<void>((result) {
        if (result == 0 || result == false) {
          throw StateError('The speech engine could not play this reply.');
        }
      });
      await Future.any([playback, cancelled.future, failed.future])
          .timeout(utteranceTimeout);
    } on TimeoutException {
      _ready = false;
      await stop();
      throw StateError('The speech engine stopped responding.');
    } catch (_) {
      if (generation == _generation) {
        _ready = false;
        await stop();
      }
      rethrow;
    } finally {
      if (identical(_cancelled, cancelled)) _cancelled = null;
      if (identical(_speechError, failed)) _speechError = null;
    }
  }

  @override
  Future<void> stop() {
    ++_generation;
    final cancelled = _cancelled;
    _cancelled = null;
    _speechError = null;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    final engine = _engine;
    if (engine == null) return _stopping;
    _stopping = _stopping.catchError((Object _) {}).then((_) async {
      await engine.stop().timeout(const Duration(seconds: 3));
    });
    return _stopping;
  }
}
