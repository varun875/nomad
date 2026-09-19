import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/utils/live_transcript.dart';

void main() {
  group('mergePartialTranscript', () {
    test('returns full text when nothing shown yet', () {
      expect(mergePartialTranscript('', 'hello world'), 'hello world');
    });

    test('latest partial wins as the transcript grows', () {
      expect(mergePartialTranscript('what is the', 'what is the time'),
          'what is the time');
    });

    test('returns the latest transcript when next is blank', () {
      expect(mergePartialTranscript('what is the', ''), 'what is the');
      expect(mergePartialTranscript('what is the', '   '), 'what is the');
    });

    test('handles a rewrite that drops the trailing words', () {
      // Recognizer emitted the full phrase, then refined it down.
      expect(mergePartialTranscript('show me the news today', 'show me the news'),
          'show me the news');
    });

    test('does not duplicate when the same partial arrives twice', () {
      expect(mergePartialTranscript('play some music', 'play some music'),
          'play some music');
    });

    test('survives an intermediate duplicate segment', () {
      expect(
        mergePartialTranscript('set a timer for ten', 'set a timer for ten minutes'),
        'set a timer for ten minutes',
      );
    });

    test('treats a disjoint transcript as the new input', () {
      expect(mergePartialTranscript('tell me a joke', 'what is up'),
          'what is up');
    });
  });
}
