import 'dart:async';

import 'package:nomad/core/services/assistant_platform_service.dart';
import 'package:nomad/core/services/speech_input_service.dart';
import 'package:nomad/core/services/voice_session_controller.dart';

class FakeListen {
  FakeListen(this.result, this.status, this.error, this.level);
  final VoiceResultCallback result;
  final void Function(String) status;
  final VoiceErrorCallback error;
  final void Function(double) level;
}

class FakeSpeechInput implements SpeechInput {
  bool available = true;
  bool permission = true;
  bool announceListening = true;
  bool recording = false;
  int initializations = 0;
  int stops = 0;
  int cancels = 0;
  Completer<bool>? initializeGate;
  Completer<void>? listenGate;
  final sessions = <FakeListen>[];
  final locales = <String>[];
  FakeListen get current => sessions.last;

  @override
  Future<bool> initialize() async {
    initializations++;
    return initializeGate == null ? available : await initializeGate!.future;
  }

  @override
  Future<bool> get hasPermission async => permission;

  @override
  Future<void> listen({
    required VoiceResultCallback onResult,
    required void Function(String) onStatus,
    required VoiceErrorCallback onError,
    required void Function(double) onSoundLevel,
    required String localeId,
  }) async {
    sessions.add(FakeListen(onResult, onStatus, onError, onSoundLevel));
    locales.add(localeId);
    await listenGate?.future;
    recording = true;
    if (announceListening) onStatus('listening');
  }

  @override
  Future<void> stop() async {
    stops++;
    recording = false;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    recording = false;
  }
}

class FakeSpeechOutput implements SpeechOutput {
  bool available = true;
  bool autoComplete = false;
  bool failSpeech = false;
  int stops = 0;
  final locales = <String>[];
  final spoken = <String>[];
  final playback = <Completer<void>>[];

  @override
  Future<bool> initialize({required String localeId}) async {
    locales.add(localeId);
    return available;
  }

  @override
  Future<void> speak(String text) async {
    if (failSpeech) throw StateError('No TTS voice');
    spoken.add(text);
    final done = Completer<void>();
    playback.add(done);
    if (autoComplete) done.complete();
    await done.future;
  }

  void finishCurrent() {
    final pending = playback.where((item) => !item.isCompleted);
    if (pending.isNotEmpty) pending.first.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    for (final item in playback) {
      if (!item.isCompleted) item.complete();
    }
  }
}

class FakeAssistantPlatform extends AssistantPlatformService {
  FakeAssistantPlatform() : super(isAndroid: false);
  final focusEvents = StreamController<void>.broadcast(sync: true);
  final launchEvents = StreamController<AssistantLaunch>.broadcast(sync: true);
  bool focusGranted = true;
  bool recognitionAvailable = true;
  bool hasFocus = false;
  int requests = 0;
  int releases = 0;
  Completer<bool>? focusGate;
  final actions = <Map<String, Object>>[];
  final settings = <String>[];

  @override
  Stream<void> get interruptions => focusEvents.stream;

  @override
  Stream<AssistantLaunch> get launches => launchEvents.stream;

  @override
  Future<bool> requestAudioFocus() async {
    requests++;
    hasFocus = await (focusGate?.future ?? Future.value(focusGranted));
    return hasFocus;
  }

  @override
  Future<bool> isSpeechRecognitionAvailable() async => recognitionAvailable;

  @override
  Future<void> releaseAudioFocus() async {
    releases++;
    hasFocus = false;
  }

  @override
  Future<bool> openSettings(String kind) async {
    settings.add(kind);
    return true;
  }

  @override
  Future<Map<String, dynamic>> executeAction(
      String action, Map<String, Object> arguments) async {
    actions.add({'action': action, ...arguments});
    return {
      'success': true,
      'message': 'Opened ${arguments['name'] ?? action}.'
    };
  }

  @override
  void dispose() {
    unawaited(focusEvents.close());
    unawaited(launchEvents.close());
    super.dispose();
  }
}

class VoiceFixture {
  final input = FakeSpeechInput();
  final output = FakeSpeechOutput();
  final platform = FakeAssistantPlatform();
  final owner = Object();
  final requests = <String>[];
  int cancellations = 0;
  VoiceReply? reply;
  Future<void> Function(String, VoiceReply)? handler;
  late final session =
      VoiceSessionController(input: input, output: output, platform: platform);

  Future<void> start({String? prompt, Object? ownerOverride}) => session.start(
        owner: ownerOverride ?? owner,
        localeId: 'en-IN',
        cancelRequest: () => cancellations++,
        initialPrompt: prompt,
        onRequest: (text, response) async {
          requests.add(text);
          reply = response;
          if (handler != null) {
            await handler!(text, response);
          } else {
            response.addText('A clear spoken answer.');
          }
        },
      );

  Future<void> dispose() async {
    await session.stop();
    session.dispose();
    platform.dispose();
  }
}
