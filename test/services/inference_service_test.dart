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
      // Each turn is ~18 chars content + role overhead (~12) = ~30 chars.
      // A budget of 70 fits ~2 newest turns.
      final result = InferenceService.trimHistoryForContext(history, 70);
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
      // Empty content still costs role overhead (~17 chars for assistant), so
      // a budget of 1 only keeps the newest turn. Budget 35 fits both.
      final result = InferenceService.trimHistoryForContext([
        {'role': 'assistant', 'content': ''},
        {'role': 'user', 'content': 'a'},
      ], 35);
      expect(result, hasLength(2));
      expect(result[0]['content'], '');
      expect(result[1]['content'], 'a');
    });
  });

  group('InferenceService.countPerformanceCores', () {
    test('returns zero for an empty map', () {
      expect(InferenceService.countPerformanceCores({}), 0);
    });

    test('counts all cores when they run at the same speed', () {
      const freqs = {0: 2000000, 1: 2000000, 2: 2000000, 3: 2000000};
      expect(InferenceService.countPerformanceCores(freqs), 4);
    });

    test('excludes big.LITTLE efficiency cores (Dimensity 6300)', () {
      // 2x A76 @ 2.4GHz, 6x A55 @ 2.0GHz. The A55 cluster runs at ~83% of the
      // peak so only the two big cores should count.
      const freqs = {
        0: 2000000,
        1: 2000000,
        2: 2000000,
        3: 2000000,
        4: 2000000,
        5: 2000000,
        6: 2400000,
        7: 2400000,
      };
      expect(InferenceService.countPerformanceCores(freqs), 2);
    });

    test('includes slightly slower performance cores (Snapdragon 8 Gen 3)', () {
      // 1x X4 @ 3.3GHz, 3x A720 @ 3.15GHz (96% of peak), 4x A520 @ 2.0GHz.
      const freqs = {
        0: 3150000,
        1: 3150000,
        2: 3150000,
        3: 3300000,
        4: 2000000,
        5: 2000000,
        6: 2000000,
        7: 2000000,
      };
      expect(InferenceService.countPerformanceCores(freqs), 4);
    });

    test('handles duplicate frequencies on identical clusters', () {
      const freqs = {
        0: 2500000,
        1: 2500000,
        2: 2500000,
        3: 2500000,
        4: 1800000,
        5: 1800000,
        6: 1800000,
        7: 1800000,
      };
      expect(InferenceService.countPerformanceCores(freqs), 4);
    });

    test('Exynos tri-cluster: X2 + A710 count, A510 excluded', () {
      // Exynos 2200: 1x X2 @ 2.8GHz, 3x A710 @ 2.52GHz (90% of peak),
      // 4x A510 @ 1.8GHz.
      const freqs = {
        0: 2520000,
        1: 2520000,
        2: 2520000,
        3: 2800000,
        4: 1800000,
        5: 1800000,
        6: 1800000,
        7: 1800000,
      };
      expect(InferenceService.countPerformanceCores(freqs), 4);
    });

    test('Tensor G2: only the prime cluster counts (conservative)', () {
      // Tensor G2: 2x X1 @ 2.85GHz, 2x A76 @ 2.35GHz (82% of peak),
      // 4x A55 @ 1.8GHz. The A76 cluster is excluded by the 90% rule. This
      // yields a smaller thread count than optimal, but never a slow setup.
      const freqs = {
        0: 2350000,
        1: 2350000,
        2: 2850000,
        3: 2850000,
        4: 1800000,
        5: 1800000,
        6: 1800000,
        7: 1800000,
      };
      expect(InferenceService.countPerformanceCores(freqs), 2);
    });

    test('budget MediaTek with A78 big cores (Dimensity 6080)', () {
      // 2x A78 @ 2.4GHz, 6x A55 @ 2.0GHz => 2 perf cores.
      const freqs = {
        0: 2000000,
        1: 2000000,
        2: 2000000,
        3: 2000000,
        4: 2000000,
        5: 2000000,
        6: 2400000,
        7: 2400000,
      };
      expect(InferenceService.countPerformanceCores(freqs), 2);
    });

    test('older homogeneous 4-core budget chip counts all cores', () {
      const freqs = {0: 1500000, 1: 1500000, 2: 1500000, 3: 1500000};
      expect(InferenceService.countPerformanceCores(freqs), 4);
    });

    test('a lonely fast core still counts as at least one perf core', () {
      const freqs = {
        0: 1800000,
        1: 1800000,
        2: 1800000,
        3: 1800000,
        4: 1800000,
        5: 1800000,
        6: 1800000,
        7: 3200000,
      };
      expect(InferenceService.countPerformanceCores(freqs), 1);
    });
  });

  group('InferenceService.resolveOptimalThreads', () {
    test('uses a hybrid thread count on Dimensity 6300', () {
      // 8 total cores with 2 big and 6 efficiency cores: use four workers
      // so decode is not limited to the fast cluster alone.
      expect(
        InferenceService.resolveOptimalThreads(
          constrained: true,
          processors: 8,
          performanceCores: 2,
        ),
        4,
      );
    });

    test('4 perf cores on an 8-core phone stays at 4', () {
      expect(
        InferenceService.resolveOptimalThreads(
          constrained: true,
          processors: 8,
          performanceCores: 4,
        ),
        4,
      );
    });

    test('homogeneous all-big chips use their full core count', () {
      // Dimensity 8400: 8x A725. All cores are performance cores.
      expect(
        InferenceService.resolveOptimalThreads(
          constrained: false,
          processors: 8,
          performanceCores: 8,
        ),
        8,
      );
    });

    test('perf count can never exceed the real processor count', () {
      expect(
        InferenceService.resolveOptimalThreads(
          constrained: true,
          processors: 4,
          performanceCores: 6,
        ),
        4,
      );
    });

    test('a degenerate one-perf-core reading is floored at 2 threads', () {
      expect(
        InferenceService.resolveOptimalThreads(
          constrained: true,
          processors: 8,
          performanceCores: 1,
        ),
        2,
      );
    });

    test('zero or absent perf count falls back to processor heuristics', () {
      expect(
        InferenceService.resolveOptimalThreads(
          constrained: true,
          processors: 8,
          performanceCores: 0,
        ),
        4,
      );
      expect(
        InferenceService.resolveOptimalThreads(
          constrained: false,
          processors: 8,
          performanceCores: null,
        ),
        7,
      );
    });

    test('tiny two-core devices get both cores', () {
      expect(
        InferenceService.resolveOptimalThreads(
          constrained: true,
          processors: 2,
          performanceCores: 2,
        ),
        2,
      );
    });

    test('entry-level 8-core phone without detection is capped at 4', () {
      expect(
        InferenceService.resolveOptimalThreads(
          constrained: true,
          processors: 8,
          performanceCores: null,
        ),
        4,
      );
    });

    test('flagship without detection respects the desktop headroom budget', () {
      // Non-constrained devices take processors-1, capped at 8 threads.
      expect(
        InferenceService.resolveOptimalThreads(
          constrained: false,
          processors: 16,
          performanceCores: null,
        ),
        8,
      );
    });
  });

  group('InferenceService.resolveOptimalBatchThreads', () {
    test('Dimensity 6300 uses all 8 cores for prompt eval', () {
      // 2x A76 + 6x A55: batched prompt eval parallelizes across all cores
      // for fast TTFT without the MediaTek decode collapse.
      expect(
        InferenceService.resolveOptimalBatchThreads(processors: 8),
        8,
      );
    });

    test('quad-core budget chip gets all 4 cores', () {
      expect(InferenceService.resolveOptimalBatchThreads(processors: 4), 4);
    });

    test('tiny two-core devices use both cores', () {
      expect(InferenceService.resolveOptimalBatchThreads(processors: 2), 2);
    });

    test('a single visible core is floored at 2 threads', () {
      expect(InferenceService.resolveOptimalBatchThreads(processors: 1), 2);
    });

    test('huge server chips are capped at 16 batch threads', () {
      expect(InferenceService.resolveOptimalBatchThreads(processors: 128), 16);
    });
  });

  group('InferenceService.classifiesAsArmv7', () {
    test('returns false for empty maps', () {
      expect(InferenceService.classifiesAsArmv7([]), isFalse);
    });

    test('returns false when libraries load from a lib/arm64 directory', () {
      final maps = [
        '/data/app/~~abc/com.varun.nomad-xyz/lib/arm64/libllama.so (rw-p)',
        '/system/lib64/libc.so (r-xp)',
      ];
      expect(InferenceService.classifiesAsArmv7(maps), isFalse);
    });

    test('returns true when libraries load from a lib/arm directory', () {
      final maps = [
        '/data/app/~~abc/com.varun.nomad-xyz/lib/arm/libllama.so (rw-p)',
        '/system/lib/libc.so (r-xp)',
      ];
      expect(InferenceService.classifiesAsArmv7(maps), isTrue);
    });

    test('arm64 marker wins even if a stray lib/arm path appears', () {
      final maps = [
        '/data/app/~~abc/com.varun.nomad-xyz/lib/arm64/libllama.so (rw-p)',
        '/system/lib/arm/test.so (r-xp)',
      ];
      expect(InferenceService.classifiesAsArmv7(maps), isFalse);
    });
  });
}
