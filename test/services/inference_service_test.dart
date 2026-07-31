import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/inference_service.dart';

void main() {
  group('InferenceService.trimHistoryForContext', () {
    List<Map<String, String>> turns(int n) => [
          for (var i = 0; i < n; i++)
            {
              'role': i.isEven ? 'user' : 'assistant',
              'content': 'turn-$i-${'x' * 10}',
            }
        ];

    test('returns an empty list for empty history', () {
      expect(InferenceService.trimHistoryForContext([], 1000), isEmpty);
    });

    test('preserves all turns in order when they fit', () {
      final history = turns(3);
      final result = InferenceService.trimHistoryForContext(history, 1000);
      expect(result, hasLength(3));
      expect(result[0]['content'], 'turn-0-xxxxxxxxxx');
      expect(result[2]['content'], 'turn-2-xxxxxxxxxx');
    });

    test('drops the oldest turns when the budget is exceeded', () {
      final history = turns(5);
      // Each turn is ~18 chars. A budget of 40 fits ~2 newest turns.
      final result = InferenceService.trimHistoryForContext(history, 40);
      expect(result, hasLength(2));
      expect(result[0]['content'], 'turn-3-xxxxxxxxxx');
      expect(result[1]['content'], 'turn-4-xxxxxxxxxx');
    });

    test('always keeps the most recent turn even if it alone exceeds budget',
        () {
      final history = turns(3);
      final result = InferenceService.trimHistoryForContext(history, 5);
      expect(result, hasLength(1));
      expect(result.single['content'], 'turn-2-xxxxxxxxxx');
    });

    test('defaults missing roles to user', () {
      final result = InferenceService.trimHistoryForContext([
        {'content': 'hello'},
      ], 1000);
      expect(result.single['role'], 'user');
      expect(result.single['content'], 'hello');
    });

    test('retains empty-content turns without consuming budget', () {
      final result = InferenceService.trimHistoryForContext([
        {'role': 'assistant', 'content': ''},
        {'role': 'user', 'content': 'a'},
      ], 1);
      expect(result, hasLength(2));
      expect(result[0]['content'], '');
      expect(result[1]['content'], 'a');
    });
  });
}
