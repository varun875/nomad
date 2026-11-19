import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/audio_capture_service.dart';
import 'package:nomad/core/services/voice_session_controller.dart';

import '../helpers/voice_fakes.dart';

class _FakeCapture implements AudioCapture {
  bool available = true;
  bool recording = false;
  double currentLevel = -160;
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

  @override
  Future<double> level() async => currentLevel;
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

  test('pause and resume keep the recorder owning the microphone', () async {
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

    try {
      await session.start(
        owner: Object(),
        onRequest: (_, reply) async {
          reply.addText('Okay.');
        },
        cancelRequest: () {},
        localeId: 'en-US',
        audioTurns: true,
      );
      expect(capture.starts, 1);
      await session.pause();
      // Resuming must not silently downgrade an audio-capable model session
      // to the system recognizer.
      await session.retry();
      expect(input.sessions, isEmpty);
      expect(capture.starts, 2);
      expect(session.phase, VoicePhase.listening);
    } finally {
      await session.stop();
      session.dispose();
      platform.dispose();
    }
  });

  test('a successful turn restarts the consecutive-silence streak', () async {
    final output = FakeSpeechOutput()..autoComplete = true;
    final platform = FakeAssistantPlatform();
    final capture = _FakeCapture();
    final session = VoiceSessionController(
      input: FakeSpeechInput(),
      output: output,
      platform: platform,
      capture: capture,
    );
    final requests = <String>[];

    Future<void> handler(String text, VoiceReply reply) async {
      requests.add(text);
      reply.addText('Okay.');
    }

    // Two silent takes in a row, then a real request. The silence counters
    // must start over: otherwise a few silent taps scattered across a session
    // permanently capped them and every later hiccup paused the voice.
    Future<void> silentTake() async {
      capture.nextPath = null;
      session.finishListening();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    try {
      await session.start(
        owner: Object(),
        onRequest: handler,
        cancelRequest: () {},
        localeId: 'en-US',
        audioTurns: true,
      );
      await silentTake();
      await silentTake();
      capture.nextPath = '/tmp/utterance.wav';
      session.finishListening();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(requests, hasLength(1));
      expect(session.phase, VoicePhase.listening);

      // Two more silences after the successful turn: still listening.
      await silentTake();
      await silentTake();
      expect(session.phase, isNot(VoicePhase.paused));

      // A third consecutive silence pauses, as designed.
      await silentTake();
      expect(session.phase, VoicePhase.paused);
      expect(session.issue, VoiceIssue.noSpeech);
    } finally {
      await session.stop();
      session.dispose();
      platform.dispose();
    }
  });

  test('audio turns finish hands-free once speech goes quiet', () async {
    final input = FakeSpeechInput();
    final output = FakeSpeechOutput()..autoComplete = true;
    final platform = FakeAssistantPlatform();
    // -30 dBFS: someone is talking.
    final capture = _FakeCapture()..currentLevel = -30;
    final session = VoiceSessionController(
      input: input,
      output: output,
      platform: platform,
      capture: capture,
    );
    final requests = <String>[];
    String? audioPath;

    Future<void> handler(String text, VoiceReply reply) async {
      requests.add(text);
      audioPath = session.lastAudioPath;
      reply.addText('Okay.');
    }

    try {
      await session.start(
        owner: Object(),
        onRequest: handler,
        cancelRequest: () {},
        localeId: 'en-US',
        audioTurns: true,
      );
      // A few 100ms level polls latch the speech.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(session.phase, VoicePhase.listening);
      // The speaker went quiet: after the default 1500ms silence hold the
      // recording finishes itself and the answer starts without a tap.
      capture.currentLevel = -70;
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(requests, ['']);
      expect(audioPath, '/tmp/utterance.wav');
    } finally {
      await session.stop();
      session.dispose();
      platform.dispose();
    }
  });
}
