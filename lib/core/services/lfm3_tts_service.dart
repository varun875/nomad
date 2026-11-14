import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
/// sentences arrive mid-generation, so playback starts right after the full
/// answer finishes generating.
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
  TextToSpeechTask? _task;
  bool _ready = false;
  bool _draining = false;
  int _generation = 0;
  int _consecutiveFailures = 0;
  final List<_PendingSentence> _queue = [];

  AudioPlayer get _audioPlayer => _player ??= AudioPlayer();

  bool get _busy => _busyImpl != null ? _busyImpl!() : _inference.isGenerating;

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
    final synth = TextToSpeechEngine.attach(
      engine,
      adapter: const Lfm3AudioTtsAdapter(),
    );
    final caps = await synth.capabilities;
    if (!caps.isSupported) return false;
    _synth = synth;
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
      final sub = player.onPlayerComplete.listen((_) {
        if (!done.isCompleted) done.complete();
      });
      try {
        await player.play(DeviceFileSource(path));
        await done.future.timeout(const Duration(seconds: 90));
      } finally {
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
  Future<void> speak(String text) async {
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
        try {
          final wav = await (_synthImpl ?? _defaultSynthesize)(
            item.text,
            voice,
          );
          if (item.generation != _generation) {
            if (!item.done.isCompleted) item.done.complete();
            continue;
          }
          await (_playImpl ?? _defaultPlay)(wav);
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
      _draining = false;
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
    final player = _player;
    if (player == null) return;
    try {
      await player.stop().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}

/// Picks LFM3 native TTS when Omni is loaded, otherwise system TTS.
class SmartSpeechOutput implements SpeechOutput {
  SmartSpeechOutput({SpeechOutput? native, SpeechOutput? system})
      : _native = native ?? Lfm3TtsService(),
        _system = system ?? TtsService();

  final SpeechOutput _native;
  final SpeechOutput _system;
  bool _useNative = false;

  @override
  Future<bool> initialize({required String localeId}) async {
    _useNative = await _native.initialize(localeId: localeId);
    if (_useNative) return true;
    return _system.initialize(localeId: localeId);
  }

  @override
  Future<void> speak(String text) =>
      _useNative ? _native.speak(text) : _system.speak(text);

  @override
  Future<void> stop() async {
    await _native.stop();
    await _system.stop();
  }
}
