import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/live_transcript.dart';
import '../utils/speech_text.dart';
import 'assistant_platform_service.dart';
import 'audio_capture_service.dart';
import 'lfm3_tts_service.dart';
import 'speech_input_service.dart';
import 'tts_service.dart';

enum VoicePhase {
  idle,
  starting,
  listening,
  processing,
  thinking,
  speaking,
  paused,
  error
}

enum VoiceIssue {
  permission,
  recognizerUnavailable,
  network,
  language,
  audioBusy,
  speakerUnavailable,
  noModel,
  responseFailed,
  noSpeech,
  interrupted,
}

class VoiceSessionException implements Exception {
  const VoiceSessionException(this.issue);
  final VoiceIssue issue;
}

typedef VoiceRequestHandler = Future<void> Function(
    String text, VoiceReply reply);

final voiceSessionProvider = Provider<VoiceSessionController>((ref) {
  final controller = VoiceSessionController(
    input: SystemSpeechInput(),
    output: SmartSpeechOutput(),
    platform: ref.watch(assistantPlatformProvider),
    capture: DeviceAudioCapture(),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// A single app-wide owner of the microphone and speaker. Screens attach only
/// when voice is explicitly requested; constructing a chat never asks for mic
/// permission. Session/listen IDs reject late callbacks after pause or navigation.
class VoiceSessionController extends ChangeNotifier {
  VoiceSessionController({
    required SpeechInput input,
    required SpeechOutput output,
    required AssistantPlatformService platform,
    AudioCapture? capture,
    this.finalResultWait = const Duration(milliseconds: 1800),
    this.silenceWait = const Duration(seconds: 3),
    this.restartDelay = const Duration(milliseconds: 400),
    this.startTimeout = const Duration(seconds: 6),
  })  : _input = input,
        _output = output,
        _platform = platform,
        _capture = capture {
    _interruptions = _platform.interruptions.listen((_) {
      if (isActive && phase != VoicePhase.paused) {
        unawaited(pause(interrupted: true));
      }
    });
  }

  final SpeechInput _input;
  final SpeechOutput _output;
  final AssistantPlatformService _platform;
  final AudioCapture? _capture;
  final Duration finalResultWait;
  final Duration silenceWait;
  final Duration restartDelay;
  final Duration startTimeout;
  late final StreamSubscription<void> _interruptions;
  final soundLevel = ValueNotifier<double>(-50);

  VoicePhase _phase = VoicePhase.idle;
  VoicePhase get phase => _phase;
  VoiceIssue? _issue;
  VoiceIssue? get issue => _issue;
  String _transcript = '';
  String get transcript => _transcript;
  String _lastHeard = '';
  String get lastHeard => _lastHeard;

  /// Path of the WAV captured for the current turn, when the selected model
  /// takes audio directly. Cleared at the start of every turn.
  String? _lastAudioPath;
  String? get lastAudioPath => _lastAudioPath;
  String _localeId = 'en-US';
  Object? _owner;
  VoiceRequestHandler? _onRequest;
  VoidCallback? _cancelRequest;
  bool _disposed = false;
  bool _listenArmed = false;
  bool _audioTurns = false;
  int _command = 0;
  int _epoch = 0;
  int _listenId = 0;
  int _emptyAttempts = 0;
  int _transientAttempts = 0;
  Completer<void>? _turnDone;
  Future<void> _audioOperations = Future.value();
  Timer? _restartTimer;
  Timer? _finalTimer;
  Timer? _silenceTimer;
  Timer? _startTimer;
  Timer? _sessionTimer;

  bool get isActive => _owner != null && phase != VoicePhase.idle;
  bool isOwnedBy(Object owner) => identical(_owner, owner) && isActive;
  bool get isResponding =>
      phase == VoicePhase.thinking || phase == VoicePhase.speaking;
  bool _current(int epoch) => !_disposed && _owner != null && epoch == _epoch;
  bool _accepts(int epoch, int listenId) =>
      _current(epoch) &&
      _listenArmed &&
      listenId == _listenId &&
      (phase == VoicePhase.starting ||
          phase == VoicePhase.listening ||
          phase == VoicePhase.processing);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _cancelTimers() {
    _restartTimer?.cancel();
    _finalTimer?.cancel();
    _silenceTimer?.cancel();
    _startTimer?.cancel();
    _sessionTimer?.cancel();
  }

  Future<T> _withAudio<T>(Future<T> Function() operation) {
    final task = _audioOperations.then((_) => operation());
    _audioOperations =
        task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  /// Cancel every audio resource even if one of the native plugins fails. The
  /// barrier also prevents a late stop() from cutting off a newly started turn.
  Future<bool> _stopAudio() {
    var succeeded = true;
    return _withAudio(() async {
      for (final operation in <Future<void> Function()>[
        _input.cancel,
        _capture?.cancel ?? () async {},
        _output.stop,
        _platform.releaseAudioFocus,
      ]) {
        try {
          await operation().timeout(const Duration(seconds: 4));
        } catch (error) {
          succeeded = false;
          debugPrint('Could not release voice audio: $error');
        }
      }
      return succeeded;
    });
  }

  Future<void> start({
    required Object owner,
    required VoiceRequestHandler onRequest,
    required VoidCallback cancelRequest,
    required String localeId,
    String? initialPrompt,
    bool audioTurns = false,
  }) async {
    if (_disposed) return;
    final command = ++_command;
    final oldTurn = _turnDone?.future;
    ++_epoch;
    ++_listenId;
    _listenArmed = false;
    _cancelTimers();
    if (_turnDone != null) _cancelRequest?.call();
    final stopped = _stopAudio();
    _owner = owner;
    _onRequest = onRequest;
    _cancelRequest = cancelRequest;
    _localeId = localeId;
    _audioTurns = audioTurns && _capture != null;
    _lastAudioPath = null;
    _phase = VoicePhase.starting;
    _issue = null;
    _transcript = '';
    _emptyAttempts = 0;
    _transientAttempts = 0;
    _changed();
    final epoch = _epoch;

    try {
      final clean = await stopped;
      // Native model cancellation may still be unwinding. Do not open a second
      // microphone turn while its answer can still write into the conversation.
      await oldTurn;
      if (!_current(epoch) || command != _command) return;
      if (!clean) throw const VoiceSessionException(VoiceIssue.audioBusy);

      if (_audioTurns) {
        // Audio-capable models hear the raw utterance, so the system recognizer
        // is skipped entirely and the microphone is owned by one recorder.
        final ready = await _capture!
            .initialize()
            .timeout(const Duration(seconds: 20));
        if (!_current(epoch)) return;
        if (!ready) {
          throw const VoiceSessionException(VoiceIssue.permission);
        }
      } else {
        if (!await _platform.isSpeechRecognitionAvailable()) {
          throw const VoiceSessionException(VoiceIssue.recognizerUnavailable);
        }
        if (!_current(epoch)) return;
        final available =
            await _input.initialize().timeout(const Duration(seconds: 45));
        if (!_current(epoch)) return;
        if (!available) {
          final permission = await _input.hasPermission;
          if (!_current(epoch)) return;
          throw VoiceSessionException(permission
              ? VoiceIssue.recognizerUnavailable
              : VoiceIssue.permission);
        }
      }
      final canSpeak = await _output
          .initialize(localeId: localeId)
          .timeout(const Duration(seconds: 12));
      if (!_current(epoch)) return;
      if (!canSpeak) {
        throw const VoiceSessionException(VoiceIssue.speakerUnavailable);
      }
      final focused = await _withAudio(() async {
        if (!_current(epoch)) return false;
        return _platform
            .requestAudioFocus()
            .timeout(const Duration(seconds: 4));
      });
      if (!_current(epoch)) return;
      if (!focused) {
        throw const VoiceSessionException(VoiceIssue.audioBusy);
      }
      if (!_current(epoch)) return;
      if (initialPrompt != null && initialPrompt.trim().isNotEmpty) {
        _transcript = initialPrompt.trim();
        _launchTurn(epoch);
      } else {
        await _beginListening(epoch);
      }
    } on VoiceSessionException catch (error) {
      if (_current(epoch)) _fail(error.issue);
    } catch (error) {
      debugPrint('Could not start voice: $error');
      if (_current(epoch)) _fail(VoiceIssue.recognizerUnavailable);
    }
  }

  Future<void> _beginListening(int epoch) async {
    if (!_current(epoch) ||
        phase == VoicePhase.paused ||
        phase == VoicePhase.error) {
      return;
    }
    final id = ++_listenId;
    _cancelTimers();
    _phase = VoicePhase.starting;
    _transcript = '';
    _lastAudioPath = null;
    soundLevel.value = -50;
    _changed();
    if (_audioTurns) {
      try {
        await _withAudio(() async {
          if (!_current(epoch) || id != _listenId) return;
          _listenArmed = true;
          _startTimer = Timer(startTimeout, () {
            if (_accepts(epoch, id) && phase == VoicePhase.starting) {
              _onError(epoch, id, 'error_busy');
            }
          });
          _sessionTimer = Timer(const Duration(seconds: 50), () {
            if (_accepts(epoch, id)) _finishListening(epoch, id);
          });
          await _capture!.start().timeout(startTimeout);
          if (!_current(epoch) || id != _listenId) return;
          _startTimer?.cancel();
          if (phase == VoicePhase.starting) {
            _phase = VoicePhase.listening;
            _changed();
          }
        });
      } catch (error) {
        debugPrint('Could not open the microphone for audio input: $error');
        if (_current(epoch) && id == _listenId) {
          _onError(epoch, id, 'error_audio_error');
        }
      }
      return;
    }
    try {
      await _withAudio(() async {
        if (!_current(epoch) || id != _listenId) return;
        await _input.cancel().timeout(const Duration(seconds: 4));
        if (!_current(epoch) || id != _listenId) return;
        _listenArmed = true;
        _startTimer = Timer(startTimeout, () {
          if (_accepts(epoch, id) && phase == VoicePhase.starting) {
            _onError(epoch, id, 'error_busy');
          }
        });
        _sessionTimer = Timer(const Duration(seconds: 50), () {
          if (_accepts(epoch, id)) _finishListening(epoch, id);
        });
        await _input
            .listen(
              localeId: _localeId,
              onResult: (text, isFinal) => _onResult(epoch, id, text, isFinal),
              onStatus: (status) => _onStatus(epoch, id, status),
              onError: (code, _) => _onError(epoch, id, code),
              onSoundLevel: (level) {
                if (_accepts(epoch, id) &&
                    phase == VoicePhase.listening &&
                    level.isFinite) {
                  soundLevel.value = level;
                }
              },
            )
            .timeout(startTimeout);
      });
    } catch (error) {
      debugPrint('Could not open microphone: $error');
      if (_current(epoch) && id == _listenId) {
        _onError(epoch, id, 'error_audio_error');
      }
    }
  }

  void _onStatus(int epoch, int id, String status) {
    if (!_accepts(epoch, id)) return;
    if (status == 'listening') {
      _startTimer?.cancel();
      if (phase == VoicePhase.starting) {
        _phase = VoicePhase.listening;
        _changed();
      }
    } else if (status == 'notListening') {
      // notListening means the mic closed, NOT that the final transcript arrived.
      _finishListening(epoch, id);
    } else if (status == 'done') {
      _completeRecognition(epoch, id);
    }
  }

  void _onResult(int epoch, int id, String text, bool isFinal) {
    if (!_accepts(epoch, id)) return;
    _startTimer?.cancel();
    if (phase == VoicePhase.starting) _phase = VoicePhase.listening;
    _transcript = mergePartialTranscript(_transcript, text);
    if (_transcript.isNotEmpty) _emptyAttempts = 0;
    _changed();
    _silenceTimer?.cancel();
    // Identical final/partial text must still finish the turn exactly once.
    if (isFinal) {
      _completeRecognition(epoch, id);
    } else if (_transcript.isNotEmpty && phase != VoicePhase.processing) {
      _silenceTimer = Timer(silenceWait, () => _finishListening(epoch, id));
    }
  }

  void _finishListening(int epoch, int id) {
    if (!_accepts(epoch, id) || phase == VoicePhase.processing) return;
    _phase = VoicePhase.processing;
    _silenceTimer?.cancel();
    _startTimer?.cancel();
    soundLevel.value = -50;
    _changed();
    if (_audioTurns) {
      _finalTimer?.cancel();
      unawaited(_withAudio(() async {
        String? path;
        try {
          path = await _capture!.stop().timeout(const Duration(seconds: 4));
        } catch (error) {
          debugPrint('Could not finish recording: $error');
        }
        if (!_accepts(epoch, id)) return;
        _listenArmed = false;
        ++_listenId;
        _cancelTimers();
        if (path == null || path.isEmpty) {
          if (++_emptyAttempts <= 2) {
            _scheduleListen(epoch);
          } else {
            _issue = VoiceIssue.noSpeech;
            unawaited(pause(keepIssue: true));
          }
          return;
        }
        _transientAttempts = 0;
        _launchTurn(epoch, audioPath: path);
      }));
      return;
    }
    _finalTimer = Timer(finalResultWait, () => _completeRecognition(epoch, id));
    unawaited(_withAudio(() async {
      if (_accepts(epoch, id)) {
        await _input.stop().timeout(const Duration(seconds: 4));
      }
    }).catchError((Object error) {
      if (_accepts(epoch, id)) _fail(VoiceIssue.audioBusy);
    }));
  }

  void finishListening() => _finishListening(_epoch, _listenId);

  void _completeRecognition(int epoch, int id) {
    if (!_accepts(epoch, id)) return;
    _listenArmed = false;
    ++_listenId;
    _cancelTimers();
    if (_transcript.trim().isNotEmpty) {
      _transientAttempts = 0;
      _launchTurn(epoch);
    } else if (++_emptyAttempts <= 2) {
      _scheduleListen(epoch);
    } else {
      _issue = VoiceIssue.noSpeech;
      unawaited(pause(keepIssue: true));
    }
  }

  void _onError(int epoch, int id, String code) {
    if (!_accepts(epoch, id)) return;
    if (code == 'error_no_match' || code == 'error_speech_timeout') {
      _completeRecognition(epoch, id);
      return;
    }
    if ((code == 'error_busy' ||
            code == 'error_client' ||
            code == 'error_server_disconnected') &&
        _transientAttempts++ < 1) {
      _listenArmed = false;
      ++_listenId;
      _cancelTimers();
      _scheduleListen(epoch, delay: const Duration(milliseconds: 900));
      return;
    }
    final issue = switch (code) {
      'error_permission' => VoiceIssue.permission,
      'error_network' ||
      'error_network_timeout' ||
      'error_server' =>
        VoiceIssue.network,
      'error_language_not_supported' ||
      'error_language_unavailable' =>
        VoiceIssue.language,
      _ => VoiceIssue.audioBusy,
    };
    _fail(issue);
  }

  void _scheduleListen(int epoch, {Duration? delay}) {
    if (!_current(epoch)) return;
    _phase = VoicePhase.starting;
    soundLevel.value = -50;
    _changed();
    _restartTimer?.cancel();
    _restartTimer = Timer(delay ?? restartDelay, () {
      if (_current(epoch)) unawaited(_beginListening(epoch));
    });
  }

  void _launchTurn(int epoch, {String? audioPath}) {
    final request = _onRequest;
    if (!_current(epoch) || request == null || _turnDone != null) return;
    final text = _transcript.trim();
    if (text.isEmpty && audioPath == null) return;
    _listenArmed = false;
    ++_listenId;
    _cancelTimers();
    _lastHeard = text;
    _lastAudioPath = audioPath;
    _phase = VoicePhase.thinking;
    _issue = null;
    soundLevel.value = -50;
    final done = Completer<void>();
    _turnDone = done;
    _changed();
    unawaited(_runTurn(epoch, request, text, done));
  }

  Future<void> _runTurn(int epoch, VoiceRequestHandler request, String text,
      Completer<void> done) async {
    bool current() =>
        _current(epoch) &&
        phase != VoicePhase.paused &&
        phase != VoicePhase.error;
    final reply = VoiceReply(
      isCurrent: current,
      onSpeechFailure: () {
        if (current()) _fail(VoiceIssue.speakerUnavailable);
      },
      speak: (sentence) async {
        if (!current()) return;
        _phase = VoicePhase.speaking;
        _changed();
        await _output.speak(sentence);
        if (current()) {
          _phase = VoicePhase.thinking;
          _changed();
        }
      },
    );
    try {
      await _withAudio(() async {
        if (current()) {
          await _input.cancel().timeout(const Duration(seconds: 4));
        }
      });
      if (!current()) return;
      await request(text, reply);
      if (!current()) return;
      // Completion is tied to the actual last utterance. There is no 30-second
      // polling cutoff that can reopen the mic while the answer is still playing.
      await reply.finish();
    } on VoiceSessionException catch (error) {
      if (current()) _fail(error.issue);
    } catch (error) {
      debugPrint('Voice turn failed: $error');
      if (current()) _fail(VoiceIssue.responseFailed);
    } finally {
      if (identical(_turnDone, done)) _turnDone = null;
      done.complete();
      if (current()) _scheduleListen(epoch);
    }
  }

  void _fail(VoiceIssue issue) {
    ++_epoch;
    ++_listenId;
    _listenArmed = false;
    _cancelTimers();
    if (_turnDone != null) _cancelRequest?.call();
    _phase = VoicePhase.error;
    _issue = issue;
    soundLevel.value = -50;
    _changed();
    unawaited(_stopAudio());
  }

  Future<void> retry() async {
    final owner = _owner;
    final request = _onRequest;
    final cancel = _cancelRequest;
    if (owner == null || request == null || cancel == null) return;
    await start(
        owner: owner,
        onRequest: request,
        cancelRequest: cancel,
        localeId: _localeId);
  }

  /// Tap-to-interrupt is explicit: stop both generation and playback before the
  /// microphone can capture the next request.
  Future<void> interrupt() => retry();

  Future<void> pause({bool interrupted = false, bool keepIssue = false}) async {
    if (!isActive) return;
    ++_command;
    ++_epoch;
    ++_listenId;
    _listenArmed = false;
    _cancelTimers();
    if (_turnDone != null) _cancelRequest?.call();
    _phase = VoicePhase.paused;
    if (!keepIssue) _issue = interrupted ? VoiceIssue.interrupted : null;
    soundLevel.value = -50;
    _changed();
    await _stopAudio();
  }

  Future<void> stop({Object? owner}) async {
    if (owner != null && !identical(_owner, owner)) return;
    ++_command;
    ++_epoch;
    ++_listenId;
    _listenArmed = false;
    _cancelTimers();
    if (_turnDone != null) _cancelRequest?.call();
    _owner = null;
    _phase = VoicePhase.idle;
    _issue = null;
    if (!_disposed) soundLevel.value = -50;
    _changed();
    await _stopAudio();
  }

  @override
  void dispose() {
    unawaited(stop());
    _disposed = true;
    unawaited(_interruptions.cancel());
    soundLevel.dispose();
    super.dispose();
  }
}

/// Streams natural sentences without blocking token generation. Every queued
/// sentence checks its turn's ownership again before touching the speaker.
class VoiceReply {
  VoiceReply(
      {required bool Function() isCurrent,
      required Future<void> Function(String) speak,
      VoidCallback? onSpeechFailure})
      : _isCurrent = isCurrent,
        _speak = speak,
        _onSpeechFailure = onSpeechFailure {
    _text = SpeechTextBuffer(_enqueue);
  }

  final bool Function() _isCurrent;
  final Future<void> Function(String) _speak;
  final VoidCallback? _onSpeechFailure;
  late final SpeechTextBuffer _text;
  Future<void> _tail = Future.value();
  bool _speechFailed = false;
  bool _finished = false;
  bool get isCurrent => _isCurrent();

  void addText(String text) {
    if (isCurrent && !_finished) _text.add(text);
  }

  void _enqueue(String sentence) {
    _tail = _tail.then((_) async {
      if (!isCurrent || _speechFailed) return;
      try {
        await _speak(sentence);
      } catch (_) {
        _speechFailed = true;
        if (isCurrent) _onSpeechFailure?.call();
      }
    });
  }

  Future<void> finish() async {
    if (!_finished) {
      _finished = true;
      _text.finish();
    }
    await _tail;
    if (_speechFailed && isCurrent) {
      throw const VoiceSessionException(VoiceIssue.speakerUnavailable);
    }
  }
}
