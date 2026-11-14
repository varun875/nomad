import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/audio_capture_service.dart';
import 'package:nomad/core/services/voice_session_controller.dart';

import '../helpers/voice_fakes.dart';

class _FakeCapture implements AudioCapture {
  bool available = true;
  bool recording = false;
  int starts = 0;
  int cancels = 0;
  String? nextPath = '/tmp/utterance.wav';

  @override
  Future<bool> initialize() async => available;

  @override
  Future<void> start() async {
    starts++;
    recording = true;
  }

  @override
  Future<String?> stop() async {
    recording = false;
    return nextPath;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    recording = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audio turns record the utterance and hand its path to the model turn',
      () async {
    final input = FakeSpeechInput();
    final output = FakeSpeechOutput()..autoComplete = true;
    final platform = FakeAssistantPlatform();
    final capture = _FakeCapture();
    final session = VoiceSessionController(
      input: input,
      output: output,
      platform: platform,
      capture: capture,
    );
    final requests = <String>[];
    String? audioPath;
    final owner = Object();

    Future<void> handler(String text, VoiceReply reply) async {
      requests.add(text);
      audioPath = session.lastAudioPath;
      reply.addText('Okay.');
    }

    try {
      await session.start(
        owner: owner,
        onRequest: handler,
        cancelRequest: () {},
        localeId: 'en-US',
        audioTurns: true,
      );
      // The recognizer must stay untouched: the recorder owns the microphone.
      expect(input.sessions, isEmpty);
      expect(capture.recording, isTrue);
      expect(session.phase, VoicePhase.listening);

      session.finishListening();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(requests, ['']);
      expect(audioPath, '/tmp/utterance.wav');
      expect(capture.recording, isFalse);
    } finally {
      await session.stop();
      session.dispose();
      platform.dispose();
    }
  });

  test('an unusable recording retries instead of sending an empty turn',
      () async {
    final capture = _FakeCapture()..nextPath = null;
    final platform = FakeAssistantPlatform();
    final session = VoiceSessionController(
      input: FakeSpeechInput(),
      output: FakeSpeechOutput()..autoComplete = true,
      platform: platform,
      capture: capture,
    );
    final requests = <String>[];
    final owner = Object();

    Future<void> handler(String text, VoiceReply reply) async {
      requests.add(text);
      reply.addText('Okay.');
    }

    try {
      await session.start(
        owner: owner,
        onRequest: handler,
        cancelRequest: () {},
        localeId: 'en-US',
        audioTurns: true,
      );
      session.finishListening();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(requests, isEmpty);
      expect(capture.starts, greaterThanOrEqualTo(1));
    } finally {
      await session.stop();
      session.dispose();
      platform.dispose();
    }
  });
}
