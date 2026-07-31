import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/utils/message_text.dart';

void main() {
  group('looksTruncated', () {
    test('is false for empty or complete text', () {
      expect(looksTruncated(''), isFalse);
      expect(looksTruncated('  '), isFalse);
      expect(looksTruncated('The answer is 42.'), isFalse);
      expect(looksTruncated('Hello'), isFalse);
    });

    test('detects trailing punctuation', () {
      expect(looksTruncated('word,'), isTrue);
      expect(looksTruncated('word:'), isTrue);
      expect(looksTruncated('word;'), isTrue);
    });

    test('detects trailing hyphen or em-dash', () {
      expect(looksTruncated('word-'), isTrue);
      expect(looksTruncated('word\u2014'), isTrue);
    });

    test('detects unclosed code fences', () {
      expect(looksTruncated('Here is the code:\n```\nvoid main'), isTrue);
    });

    test('is false for closed code fences', () {
      expect(looksTruncated('```\nvoid main() {}\n```'), isFalse);
    });
  });

  group('extractThinking', () {
    test('returns empty for plain text', () {
      expect(extractThinking('Just an answer.'), '');
      expect(extractThinking(''), '');
    });

    test('extracts legacy <think> blocks', () {
      expect(
        extractThinking('Before <think>inner reasoning</think> after'),
        'inner reasoning',
      );
    });

    test('extracts channel thought format and strips the label', () {
      expect(
        extractThinking('<|channel>thought my analysis<channel|>Answer'),
        'my analysis',
      );
    });

    test('extracts <|think|> up to the turn marker', () {
      expect(
        extractThinking('<|think|>\nstep-by-step reasoning<|turn>modelFinal'),
        'step-by-step reasoning',
      );
    });

    test('extracts <|think|> content to end of string when no turn marker',
        () {
      expect(extractThinking('<|think|>\nreasoning only'), 'reasoning only');
    });

    test('returns empty when thinking content is blank', () {
      expect(extractThinking('<think></think> answer'), '');
    });
  });

  group('stripThinkingTags', () {
    test('removes all supported reasoning formats and trims', () {
      final input =
          '<|think|>\nsteps<|turn>model<think>old</think>Final answer here.';
      expect(stripThinkingTags(input), 'Final answer here.');
    });

    test('removes channel thought blocks', () {
      expect(
        stripThinkingTags('<|channel>thought hidden<channel|>Visible reply'),
        'Visible reply',
      );
    });

    test('leaves plain text untouched', () {
      expect(stripThinkingTags('  just text  '), 'just text');
    });
  });
}
