import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/utils/speech_text.dart';

void main() {
  List<String> spoken(String input, {int chunkSize = 1}) {
    final sentences = <String>[];
    final parser = SpeechTextBuffer(sentences.add);
    for (var i = 0; i < input.length; i += chunkSize) {
      parser.add(input.substring(i, (i + chunkSize).clamp(0, input.length)));
    }
    parser.finish();
    parser.finish();
    return sentences;
  }

  test('streams sentences and a final sentence without trailing whitespace',
      () {
    expect(spoken('Hello there. How can I help?'),
        ['Hello there.', 'How can I help?']);
  });

  test(
      'reasoning never leaks even when every delimiter crosses a token boundary',
      () {
    for (final hidden in [
      '<think>Private reasoning. <think>Nested reasoning.</think></think>',
      '<|channel>thought Private reasoning.<channel|>',
      '<|think|>Private reasoning.<|turn>model',
      '```python\nprint("Private code.")\n```',
    ]) {
      for (var chunk = 1; chunk <= 12; chunk++) {
        expect(spoken('$hidden Visible answer.', chunkSize: chunk),
            ['Visible answer.']);
      }
    }
  });

  test('an incomplete reasoning or code block is never spoken', () {
    expect(spoken('<think>Still thinking. No closing marker'), isEmpty);
    expect(spoken('An answer. ```code that never closes'), ['An answer.']);
    expect(spoken('Visible. <thi'), ['Visible.']);
  });

  test('inline code and markdown do not get read as syntax', () {
    expect(spoken('Use `hidden code` for **the answer**.'),
        ['Use for the answer.']);
    expect(
        spoken('Read [the guide](https://example.com/guide).', chunkSize: 50),
        ['Read the guide.']);
  });

  test('numbers and non-English words are preserved', () {
    expect(spoken('The answer is 3.14. नमस्ते दुनिया!'),
        ['The answer is 3.14.', 'नमस्ते दुनिया!']);
  });

  test('long speech is split into bounded utterances', () {
    final result =
        spoken('${List.filled(400, 'word').join(' ')}.', chunkSize: 31);
    expect(result.length, greaterThan(1));
    expect(result.every((chunk) => chunk.length <= 361), isTrue);
    expect(result.join(' '), '${List.filled(400, 'word').join(' ')}.');
  });
}
