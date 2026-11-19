import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Microphone capture for models that accept audio input directly. Speech is
/// recorded as 16 kHz mono WAV, the format the on-device audio encoders expect.
///
/// This boundary is injectable so session ordering can be tested without a
/// real microphone, mirroring [SpeechInput].
abstract class AudioCapture {
  /// Requests microphone access and checks that WAV recording is supported.
  Future<bool> initialize();

  /// Starts a new recording, discarding any unfinished one.
  Future<void> start();

  /// Stops recording and returns the file path, or null when nothing usable
  /// was captured.
  Future<String?> stop();

  /// Stops and deletes the current recording.
  Future<void> cancel();

  /// One-shot current input level in dBFS (negative; very negative when
  /// nothing is captured). Polled while listening to drive the level orb and
  /// the hands-free end-of-speech cutoff.
  Future<double> level();
}

class DeviceAudioCapture implements AudioCapture {
  DeviceAudioCapture({
    AudioRecorder? recorder,
    Future<Directory> Function()? directory,
  })  : _injected = recorder,
        _directory = directory ?? getTemporaryDirectory;

  final AudioRecorder? _injected;

  /// Built on first use: `AudioRecorder()` registers its platform channel in
  /// the constructor, so creating it eagerly made merely opening a chat ask
  /// the host for a recorder (and threw in widget tests).
  late final AudioRecorder _created = AudioRecorder();
  AudioRecorder get _recorder => _injected ?? _created;
  final Future<Directory> Function() _directory;
  Future<bool>? _initializing;
  String? _path;
  bool _ready = false;

  /// 16 kHz mono WAV: what LFM3 and Gemma audio encoders take, and small
  /// enough to hand to the native layer without conversion.
  static const config = RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
  );

  @override
  Future<bool> initialize() async {
    if (_ready) return true;
    final inProgress = _initializing;
    if (inProgress != null) return inProgress;
    final operation = _prepare();
    _initializing = operation;
    try {
      return await operation;
    } finally {
      if (identical(_initializing, operation)) _initializing = null;
    }
  }

  Future<bool> _prepare() async {
    try {
      // A denied request must not be cached: the user can grant access in
      // Settings and retry without restarting the app.
      if (!await _recorder.hasPermission()) return false;
      if (!await _recorder.isEncoderSupported(AudioEncoder.wav)) return false;
      _ready = true;
      return true;
    } catch (error) {
      debugPrint('Could not prepare audio capture: $error');
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (!_ready && !await initialize()) {
      throw StateError('Audio capture is unavailable.');
    }
    // A stop() that failed at the platform level leaves the recorder live
    // while the Dart-side path is already cleared, and [cancel]'s cheap guard
    // then skips the native call. Reset for real so the next take cannot
    // collide with the abandoned session.
    try {
      if (await _recorder.isRecording()) {
        await _recorder.cancel();
      }
    } catch (error) {
      debugPrint('Could not reset audio capture: $error');
    }
    final directory = await _directory();
    final path =
        '${directory.path}/nomad_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(config, path: path);
    _path = path;
  }

  @override
  Future<String?> stop() async {
    if (_path == null) return null;
    _path = null;
    try {
      return await _recorder.stop();
    } catch (error) {
      if (Platform.isAndroid || Platform.isIOS) {
        debugPrint('Could not stop audio capture: $error');
      }
      return null;
    }
  }

  @override
  Future<void> cancel() async {
    // Nothing was started: skipping the platform call keeps voice teardown
    // instant on hosts (and in tests) that never opened a recorder.
    if (_path == null) return;
    _path = null;
    try {
      await _recorder.cancel();
    } catch (error) {
      debugPrint('Could not cancel audio capture: $error');
    }
  }

  @override
  Future<double> level() async {
    try {
      return (await _recorder.getAmplitude()).current;
    } catch (error) {
      debugPrint('Could not read the input level: $error');
      return -160;
    }
  }
}
