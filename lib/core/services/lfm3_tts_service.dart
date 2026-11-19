import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

import 'inference_service.dart';
import 'speech_input_service.dart';
import 'tts_service.dart';

class _PendingSentence {
  _PendingSentence(this.text, this.generation) : done = Completer<void>();

  final String text;
  final int generation;
  final Completer<void> done;
}

/// A synthesized sentence waiting for its turn in the playback pump.
class _PlaybackItem {
  _PlaybackItem(this.pending, this.wav);

  final _PendingSentence pending;
  final Uint8List wav;
}

/// Native on-device speech output via LFM3-Audio (LFM3-Omni) TTS.
///
/// When the loaded model is Nomad Omni, answers are synthesized with
/// `TextToSpeechEngine` + `Lfm3AudioTtsAdapter` attached to the *same*
/// `LlamaEngine` the chat inference uses (no second model load). PCM comes
/// back as a complete 24 kHz mono buffer; it is rendered to WAV with
/// `result.toWavBytes()` and played with `audioplayers`.
///
/// Voices: `female` (default) and `male`. No speaker reference.
///
/// Chat generation and TTS share one engine lease, so they must not overlap:
/// sentences queue up and are synthesized only once
/// [InferenceService.isGenerating] is false. In a voice turn the first
/// sentences arrive mid-generation, so native playback starts right after the
/// full answer finishes generating.
///
/// Playback itself is pipelined: synthesis runs ahead of the player, so
/// sentence N+1 is already decoded while sentence N is still playing. The
/// [SmartSpeechOutput] hybrid opening covers the one gap this cannot close:
/// the reply's first sentence is spoken by the system engine while the model
/// is still generating.
///
/// [SmartSpeechOutput] falls back to system `flutter_tts` whenever this
/// service is not ready (non-Omni model, engine not loaded, or the runtime
/// does not support LFM3 TTS).
class Lfm3TtsService implements SpeechOutput {
  Lfm3TtsService({
    InferenceService? inference,
    AudioPlayer? player,
    this.voice = 'female',
    @visibleForTesting Future<bool> Function()? initImpl,
    @visibleForTesting
    Future<Uint8List> Function(String text, String voice)? synthImpl,
    @visibleForTesting Future<void> Function(Uint8List wavBytes)? playImpl,
    @visibleForTesting bool Function()? busyImpl,
  })  : _inference = inference ?? InferenceService(),
        _player = player,
        _initImpl = initImpl,
        _synthImpl = synthImpl,
        _playImpl = playImpl,
        _busyImpl = busyImpl;

  final InferenceService _inference;
  AudioPlayer? _player;
  final Future<bool> Function()? _initImpl;
  final Future<Uint8List> Function(String text, String voice)? _synthImpl;
  final Future<void> Function(Uint8List wavBytes)? _playImpl;
  final bool Function()? _busyImpl;

  /// Which voice to speak with. LFM3-Omni ships `female` and `male`.
  String voice;

  /// Clamps to a voice LFM3-Omni actually ships.
  void setVoice(String value) {
    final v = value.toLowerCase();
    if (v == 'male' || v == 'female') voice = v;
  }

  TextToSpeechEngine? _synth;
  LlamaEngine? _synthEngine;
  TextToSpeechTask? _task;
  bool _ready = false;
  bool _draining = false;
  bool _playingBack = false;
  int _generation = 0;
  int _consecutiveFailures = 0;
  /// Playback currently handed to the audio player, completed by [stop] when
  /// it cuts the utterance off (a stopped player never emits
  /// `onPlayerComplete`).
  Completer<void>? _playback;
  final List<_PendingSentence> _queue = [];

  /// Synthesized sentences waiting for the playback pump, in order. Capped so
  /// a long answer cannot pile up decoded audio in memory while the player
  /// works through earlier sentences.
  final List<_PlaybackItem> _playbackQueue = [];
  static const int _maxPlaybackAhead = 6;

  AudioPlayer get _audioPlayer => _player ??= AudioPlayer();

  bool get _busy => _busyImpl != null ? _busyImpl() : _inference.isGenerating;

  @override
  Future<bool> initialize({required String localeId}) async {
    final gen = ++_generation;
    try {
      final ready = await (_initImpl ?? _defaultInitialize)();
      if (gen != _generation) return false;
      _ready = ready;
      _consecutiveFailures = 0;
      return ready;
    } catch (error) {
      if (gen == _generation) {
        debugPrint('LFM3 TTS unavailable: $error');
      }
      _ready = false;
      return false;
    }
  }

  Future<bool> _defaultInitialize() async {
    final engine = _inference.engine;
    if (engine == null || !_inference.isOmniLoaded) return false;
    // Attaching and probing capabilities costs a native round trip on every
    // voice start; keep the wrapper while the same engine is still loaded.
    if (identical(engine, _synthEngine) && _synth != null) return true;
    final synth = TextToSpeechEngine.attach(
      engine,
      adapter: const Lfm3AudioTtsAdapter(),
    );
    final caps = await synth.capabilities;
    if (!caps.isSupported) return false;
    _synth = synth;
    _synthEngine = engine;
    return true;
  }

  Future<Uint8List> _defaultSynthesize(String text, String voice) async {
    final synth = _synth;
    if (synth == null) throw StateError('LFM3 TTS is not available.');
    final task = await synth.synthesize(
      TextToSpeechRequest(text: text, voice: voice),
    );
    _task = task;
    final result = await task.result;
    if (identical(_task, task)) _task = null;
    return result.toWavBytes();
  }

  Future<void> _defaultPlay(Uint8List wavBytes) async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/nomad_lfm3_tts_${DateTime.now().millisecondsSinceEpoch}.wav';
    await File(path).writeAsBytes(wavBytes);
    try {
      final player = _audioPlayer;
      final done = Completer<void>();
      _playback = done;
      final sub = player.onPlayerComplete.listen((_) {
        if (!done.isCompleted) done.complete();
      });
      try {
        await player.play(
          DeviceFileSource(path),
          // The voice session already holds exclusive audio focus for the
          // whole conversation. A second permanent request from this player
          // is reported to that very session as AUDIOFOCUS_LOSS, which
          // paused every reply mid-sentence ("Voice paused - Audio was
          // interrupted"). Borrow the focus transiently instead, exactly
          // like the system speech engine the session already tolerates.
          ctx: defaultTargetPlatform == TargetPlatform.android
              ? AudioContext(
                  android: const AudioContextAndroid(
                    audioFocus: AndroidAudioFocus.gainTransientMayDuck,
                  ),
                )
              : null,
        );
        await done.future.timeout(const Duration(seconds: 90));
      } finally {
        if (identical(_playback, done)) _playback = null;
        await sub.cancel();
      }
    } finally {
      try {
        await File(path).delete();
      } catch (_) {
        // Best-effort cleanup; the OS cache reclaim handles leftovers.
      }
    }
  }

  @override
  Future<void> speak(String text, {bool first = false}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (!_ready) throw StateError('LFM3 TTS is not available.');
    final pending = _PendingSentence(trimmed, _generation);
    _queue.add(pending);
    unawaited(_drain());
    return pending.done.future;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final item = _queue.removeAt(0);
        if (item.generation != _generation) {
          if (!item.done.isCompleted) item.done.complete();
          continue;
        }
        // Chat generation and TTS share one engine lease: wait for the
        // answer to finish generating before synthesizing the first sentence.
        while (_busy && item.generation == _generation) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (item.generation != _generation) {
          if (!item.done.isCompleted) item.done.complete();
          continue;
        }
        // Synthesis runs ahead of playback, never too far: bounded memory.
        while (_playbackQueue.length >= _maxPlaybackAhead &&
            item.generation == _generation) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (item.generation != _generation) {
          if (!item.done.isCompleted) item.done.complete();
          continue;
        }
        try {
          final wav = await (_synthImpl ?? _defaultSynthesize)(
            item.text,
            voice,
          );
          if (item.generation != _generation) {
            if (!item.done.isCompleted) item.done.complete();
            continue;
          }
          // Hand playback off and keep synthesizing: the player and the
          // model engine are independent, so the next sentence's audio is
          // ready the moment the current one finishes playing.
          _playbackQueue.add(_PlaybackItem(item, wav));
          unawaited(_pumpPlayback());
        } catch (error) {
          _consecutiveFailures++;
          debugPrint('LFM3 TTS sentence failed: $error');
          if (_consecutiveFailures >= 2 && !item.done.isCompleted) {
            item.done.completeError(error);
          } else if (!item.done.isCompleted) {
            // One flaky sentence is skipped; the text reply is still shown.
            item.done.complete();
          }
        }
      }
    } finally {
      _draining = false;
    }
  }

  /// Plays synthesized sentences strictly in order while the synth loop runs
  /// ahead of it.
  Future<void> _pumpPlayback() async {
    if (_playingBack) return;
    _playingBack = true;
    try {
      while (_playbackQueue.isNotEmpty) {
        final entry = _playbackQueue.removeAt(0);
        final item = entry.pending;
        if (item.generation != _generation) {
          if (!item.done.isCompleted) item.done.complete();
          continue;
        }
        try {
          await (_playImpl ?? _defaultPlay)(entry.wav);
          _consecutiveFailures = 0;
          if (!item.done.isCompleted) item.done.complete();
        } catch (error) {
          _consecutiveFailures++;
          debugPrint('LFM3 TTS sentence failed: $error');
          if (_consecutiveFailures >= 2 && !item.done.isCompleted) {
            item.done.completeError(error);
          } else if (!item.done.isCompleted) {
            // One flaky sentence is skipped; the text reply is still shown.
            item.done.complete();
          }
        }
      }
    } finally {
      _playingBack = false;
    }
  }

  @override
  Future<void> stop() async {
    ++_generation;
    final task = _task;
    _task = null;
    task?.cancel();
    for (final pending in _queue) {
      if (!pending.done.isCompleted) pending.done.complete();
    }
    _queue.clear();
    for (final entry in _playbackQueue) {
      if (!entry.pending.done.isCompleted) entry.pending.done.complete();
    }
    _playbackQueue.clear();
    // Playback already handed to the player never reports completion once it
    // is stopped; finish it so the drain queue cannot sit blocked on it for
    // the full utterance timeout after an interruption.
    final playback = _playback;
    _playback = null;
    if (playback != null && !playback.isCompleted) playback.complete();
    final player = _player;
    if (player == null) return;
    try {
      await player.stop().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}

/// Picks LFM3 native TTS when Omni is loaded, otherwise system TTS.
///
/// With [hybridOpening], the reply's opening sentence is spoken by the system
/// engine as soon as it exists: it runs independently of the model engine,
/// while LFM3 synthesis must wait for generation to finish. The native voice
/// takes over for the rest of the answer.
class SmartSpeechOutput implements SpeechOutput {
  SmartSpeechOutput({
    SpeechOutput? native,
    SpeechOutput? system,
    this.hybridOpening = true,
  })  : _native = native ?? Lfm3TtsService(),
        _system = system ?? TtsService();

  final SpeechOutput _native;
  final SpeechOutput _system;

  /// Speak the reply's first sentence with the system voice for instant
  /// feedback while the model is still generating.
  final bool hybridOpening;
  bool _useNative = false;
  bool _systemReady = false;

  @override
  Future<bool> initialize({required String localeId}) async {
    _useNative = await _native.initialize(localeId: localeId);
    if (_useNative) {
      if (!hybridOpening) return true;
      // Warm the system engine as well so the opening sentence has somewhere
      // to go; a failure just keeps the whole answer in the native voice.
      try {
        _systemReady = await _system.initialize(localeId: localeId);
      } catch (_) {
        _systemReady = false;
      }
      return true;
    }
    _systemReady = await _system.initialize(localeId: localeId);
    return _systemReady;
  }

  @override
  Future<void> speak(String text, {bool first = false}) {
    if (_useNative) {
      if (first && hybridOpening && _systemReady) {
        return _system.speak(text, first: first);
      }
      return _native.speak(text, first: first);
    }
    return _system.speak(text, first: first);
  }

  @override
  Future<void> stop() async {
    await _native.stop();
    await _system.stop();
  }
}
