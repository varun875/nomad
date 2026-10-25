import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/voice_session_controller.dart';

import '../helpers/voice_fakes.dart';

void main() {
  late VoiceFixture voice;
  void voiceTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      voice = VoiceFixture();
      try {
        await body(tester);
      } finally {
        // Dispose in the same fake-async zone as the controller's audio queue.
        final disposed = voice.dispose();
        await tester.pump();
        await disposed;
        await tester.pump();
      }
    });
  }

  voiceTest('constructing voice does not initialize speech or open the mic',
      (tester) async {
    expect(voice.session.phase, VoicePhase.idle);
    expect(voice.input.initializations, 0);
    expect(voice.output.locales, isEmpty);
    expect(voice.input.sessions, isEmpty);
  });

  voiceTest('permission denial can recover without an app restart',
      (tester) async {
    voice.input.available = false;
    voice.input.permission = false;
    await voice.start();
    expect(voice.session.issue, VoiceIssue.permission);
    expect(voice.input.sessions, isEmpty);
    voice.input.available = true;
    voice.input.permission = true;
    await voice.session.retry();
    expect(voice.session.phase, VoicePhase.listening);
    expect(voice.input.initializations, 2);
    expect(voice.input.locales, ['en-IN']);
    expect(voice.output.locales, ['en-IN']);
  });

  voiceTest(
      'a missing external recognition provider is not mistaken for permission denial',
      (tester) async {
    voice.platform.recognitionAvailable = false;
    await voice.start();
    expect(voice.session.issue, VoiceIssue.recognizerUnavailable);
    expect(voice.input.initializations, 0);
    voice.platform.recognitionAvailable = true;
    await voice.session.retry();
    expect(voice.session.phase, VoicePhase.listening);
  });

  voiceTest(
      'notListening waits for the corrected final transcript and sends once',
      (tester) async {
    await voice.start();
    final capture = voice.input.current;
    capture.result('weather in New York today', false);
    capture.result('weather in New York', false);
    capture.status('notListening');
    await tester.pump(const Duration(milliseconds: 500));
    expect(voice.requests, isEmpty);
    expect(voice.input.sessions, hasLength(1));
    capture.result('weather in Newark', true);
    capture.status('done');
    capture.result('weather in Newark', true);
    await tester.pump();
    expect(voice.requests, ['weather in Newark']);
    expect(voice.input.recording, isFalse);
    expect(voice.output.spoken, ['A clear spoken answer.']);
  });

  voiceTest(
      'identical final text is submitted immediately, not after the silence timer',
      (tester) async {
    await voice.start();
    voice.input.current.result('tell me a joke', false);
    voice.input.current.result('tell me a joke', true);
    await tester.pump();
    expect(voice.requests, ['tell me a joke']);
    expect(voice.session.phase, VoicePhase.speaking);
  });

  voiceTest('partial silence requests a final result before using the fallback',
      (tester) async {
    await voice.start();
    voice.input.current.result('set a timer for ten', false);
    await tester.pump(const Duration(seconds: 3));
    expect(voice.input.stops, 1);
    expect(voice.requests, isEmpty);
    voice.input.current.result('set a timer for ten minutes', true);
    await tester.pump();
    expect(voice.requests.single, 'set a timer for ten minutes');
  });

  voiceTest('a missing native final result falls back once to the last partial',
      (tester) async {
    await voice.start();
    final capture = voice.input.current;
    capture.result('explain gravity', false);
    capture.status('notListening');
    await tester.pump(const Duration(seconds: 2));
    expect(voice.requests, ['explain gravity']);
    capture.result('a late correction', true);
    await tester.pump();
    expect(voice.requests, hasLength(1));
  });

  voiceTest(
      'all spoken sentences drain even beyond 30 seconds before listening again',
      (tester) async {
    voice.handler =
        (_, reply) async => reply.addText('First sentence. Second sentence.');
    await voice.start();
    final capture = voice.input.current;
    capture.result('tell me something', true);
    await tester.pump();
    expect(voice.output.spoken, ['First sentence.']);
    await tester.pump(const Duration(seconds: 40));
    capture.status('done');
    capture.result('the speaker echo', true);
    expect(voice.input.sessions, hasLength(1));
    expect(voice.requests, hasLength(1));
    voice.output.finishCurrent();
    await tester.pump();
    expect(voice.output.spoken, ['First sentence.', 'Second sentence.']);
    expect(voice.input.sessions, hasLength(1));
    voice.output.finishCurrent();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(voice.input.sessions, hasLength(2));
    expect(voice.session.phase, VoicePhase.listening);
    voice.input.current.result('and what about the next one', true);
    await tester.pump();
    expect(voice.requests, hasLength(2));
  });

  voiceTest(
      'pause cancels playback and ignores queued and future response tokens',
      (tester) async {
    final generation = Completer<void>();
    voice.handler = (_, reply) async {
      reply.addText('First sentence. Queued sentence. ');
      await generation.future;
      reply.addText('Late sentence.');
    };
    await voice.start();
    voice.input.current.result('a long answer', true);
    await tester.pump();
    expect(voice.output.spoken, ['First sentence.']);
    await voice.session.pause();
    generation.complete();
    await tester.pump(const Duration(seconds: 5));
    expect(voice.output.spoken, ['First sentence.']);
    expect(voice.session.phase, VoicePhase.paused);
    expect(voice.cancellations, 1);
    expect(voice.input.sessions, hasLength(1));
    expect(voice.platform.hasFocus, isFalse);
  });

  voiceTest('interrupt waits for the previous generation to unwind',
      (tester) async {
    final generation = Completer<void>();
    voice.handler = (_, reply) async {
      reply.addText('Let me explain. ');
      await generation.future;
    };
    await voice.start();
    voice.input.current.result('explain this', true);
    await tester.pump();
    final interrupted = voice.session.interrupt();
    await tester.pump();
    expect(voice.cancellations, 1);
    expect(voice.input.sessions, hasLength(1));
    generation.complete();
    await interrupted;
    expect(voice.input.sessions, hasLength(2));
    expect(voice.session.phase, VoicePhase.listening);
  });

  voiceTest(
      'stopping during permission initialization cannot reopen the microphone',
      (tester) async {
    voice.input.initializeGate = Completer<bool>();
    final starting = voice.start();
    await tester.pump();
    await voice.session.stop();
    voice.input.initializeGate!.complete(true);
    await starting;
    expect(voice.input.sessions, isEmpty);
    expect(voice.output.locales, isEmpty);
    expect(voice.session.phase, VoicePhase.idle);
  });

  voiceTest('a late listen completion is canceled before stop finishes',
      (tester) async {
    voice.input.listenGate = Completer<void>();
    final starting = voice.start();
    await tester.pump();
    expect(voice.input.sessions, hasLength(1));
    final stopping = voice.session.stop();
    voice.input.listenGate!.complete();
    await starting;
    await stopping;
    expect(voice.input.recording, isFalse);
    expect(voice.session.phase, VoicePhase.idle);
    expect(voice.platform.hasFocus, isFalse);
  });

  voiceTest('a delayed audio-focus grant is released after cancellation',
      (tester) async {
    voice.platform.focusGate = Completer<bool>();
    final starting = voice.start();
    await tester.pump();
    final stopping = voice.session.stop();
    voice.platform.focusGate!.complete(true);
    await starting;
    await stopping;
    expect(voice.platform.hasFocus, isFalse);
    expect(voice.input.sessions, isEmpty);
  });

  voiceTest(
      'old owners and late callbacks cannot stop or corrupt a new session',
      (tester) async {
    await voice.start();
    final old = voice.input.current;
    final newOwner = Object();
    await voice.start(ownerOverride: newOwner);
    await voice.session.stop(owner: voice.owner);
    old.status('done');
    old.error('error_permission', true);
    old.result('stale text', true);
    old.level(99);
    expect(voice.session.isOwnedBy(newOwner), isTrue);
    expect(voice.session.phase, VoicePhase.listening);
    expect(voice.requests, isEmpty);
    expect(voice.session.transcript, isEmpty);
    expect(voice.session.soundLevel.value, -50);
  });

  voiceTest('silence retries are bounded and release the microphone',
      (tester) async {
    await voice.start();
    for (var i = 0; i < 3; i++) {
      voice.input.current.error('error_no_match', true);
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(voice.input.sessions, hasLength(3));
    expect(voice.session.phase, VoicePhase.paused);
    expect(voice.session.issue, VoiceIssue.noSpeech);
    expect(voice.input.recording, isFalse);
    await tester.pump(const Duration(minutes: 5));
    expect(voice.input.sessions, hasLength(3));
  });

  voiceTest(
      'network and permission errors are surfaced without a restart storm',
      (tester) async {
    await voice.start();
    voice.input.current.error('error_network', true);
    await tester.pump(const Duration(seconds: 30));
    expect(voice.session.issue, VoiceIssue.network);
    expect(voice.input.sessions, hasLength(1));
    expect(voice.input.recording, isFalse);
    await voice.session.retry();
    voice.input.current.error('error_permission', true);
    await tester.pump();
    expect(voice.session.issue, VoiceIssue.permission);
    expect(voice.input.sessions, hasLength(2));
  });

  voiceTest(
      'a recognizer that never starts gets one retry then a visible error',
      (tester) async {
    voice.input.announceListening = false;
    await voice.start();
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 6));
    expect(voice.input.sessions, hasLength(2));
    expect(voice.session.phase, VoicePhase.error);
    expect(voice.session.issue, VoiceIssue.audioBusy);
  });

  voiceTest('audio interruption pauses until explicitly resumed',
      (tester) async {
    await voice.start();
    voice.platform.focusEvents.add(null);
    await tester.pump(const Duration(seconds: 5));
    expect(voice.session.phase, VoicePhase.paused);
    expect(voice.session.issue, VoiceIssue.interrupted);
    expect(voice.input.recording, isFalse);
    await voice.session.retry();
    expect(voice.session.phase, VoicePhase.listening);
  });

  voiceTest('speech and model failures release audio and permit a new request',
      (tester) async {
    voice.output.failSpeech = true;
    await voice.start();
    voice.input.current.result('hello', true);
    await tester.pump();
    expect(voice.session.issue, VoiceIssue.speakerUnavailable);
    expect(voice.input.recording, isFalse);
    voice.output.failSpeech = false;
    voice.handler =
        (_, __) async => throw const VoiceSessionException(VoiceIssue.noModel);
    await voice.session.retry();
    voice.input.current.result('hello again', true);
    await tester.pump();
    expect(voice.session.issue, VoiceIssue.noModel);
  });

  voiceTest(
      'transcribed assistant launch does not open the mic before its answer',
      (tester) async {
    await voice.start(prompt: 'a supplied request');
    await tester.pump();
    expect(voice.requests, ['a supplied request']);
    expect(voice.input.sessions, isEmpty);
    expect(voice.session.phase, VoicePhase.speaking);
    voice.output.finishCurrent();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(voice.input.sessions, hasLength(1));
  });

  voiceTest('speaker failure is surfaced without waiting for a long generation',
      (tester) async {
    final generation = Completer<void>();
    voice.output.failSpeech = true;
    voice.handler = (_, reply) async {
      reply.addText('A first sentence. ');
      await generation.future;
    };
    await voice.start();
    voice.input.current.result('a long answer', true);
    await tester.pump();
    expect(voice.session.issue, VoiceIssue.speakerUnavailable);
    expect(voice.cancellations, 1);
    generation.complete();
    await tester.pump();
    expect(voice.input.sessions, hasLength(1));
  });
}
