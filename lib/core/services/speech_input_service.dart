import 'package:speech_to_text/speech_to_text.dart';

typedef VoiceResultCallback = void Function(String text, bool isFinal);
typedef VoiceErrorCallback = void Function(String code, bool permanent);

/// The microphone boundary is injectable so session ordering can be tested
/// without asking for permissions or opening a real microphone.
abstract class SpeechInput {
  Future<bool> initialize();
  Future<bool> get hasPermission;
  Future<void> listen({
    required VoiceResultCallback onResult,
    required void Function(String) onStatus,
    required VoiceErrorCallback onError,
    required void Function(double) onSoundLevel,
    required String localeId,
  });
  Future<void> stop();
  Future<void> cancel();
}

class SystemSpeechInput implements SpeechInput {
  SystemSpeechInput({SpeechToText? speech})
      : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  Future<bool>? _initializing;

  @override
  Future<bool> initialize() async {
    if (_speech.isAvailable) return true;
    // A denied request must not be cached forever: the user may grant access in
    // Settings and return to Retry without restarting the application.
    final operation = _initializing ??= _speech.initialize(
      finalTimeout: const Duration(milliseconds: 1200),
    );
    try {
      return await operation;
    } finally {
      if (identical(_initializing, operation)) _initializing = null;
    }
  }

  @override
  Future<bool> get hasPermission => _speech.hasPermission;

  @override
  Future<void> listen({
    required VoiceResultCallback onResult,
    required void Function(String) onStatus,
    required VoiceErrorCallback onError,
    required void Function(double) onSoundLevel,
    required String localeId,
  }) async {
    // speech_to_text is a singleton and initialize() does not replace listeners
    // after its first success. Bind them for every session, not to a dead screen.
    _speech.statusListener = onStatus;
    _speech.errorListener = (error) => onError(error.errorMsg, error.permanent);
    await _speech.listen(
      onResult: (result) =>
          onResult(result.recognizedWords, result.finalResult),
      onSoundLevelChange: onSoundLevel,
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        partialResults: true,
        // The controller owns cancellation and retry; a second automatic cancel
        // from the plugin can otherwise race the next listen call.
        cancelOnError: false,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(seconds: 45),
        pauseFor: const Duration(seconds: 3),
        onDevice: false,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}

abstract class SpeechOutput {
  Future<bool> initialize({required String localeId});

  /// Completes when this utterance finishes playing, not when it is queued.
  /// [first] marks the opening sentence of a reply, letting a hybrid output
  /// start it on an independent engine while the model is still generating.
  Future<void> speak(String text, {bool first = false});
  Future<void> stop();
}
