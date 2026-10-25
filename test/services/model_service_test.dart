import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/model_service.dart';

void main() {
  group('ModelService recommendations', () {
    test('4 GB onboarding recommends only Nano and Lite', () async {
      final models = await ModelService.getRecommendedModels(ramGB: 4);
      expect(models.map((model) => model.name), ['Nomad Nano', 'Nomad Lite']);
    });

    test('the full catalog is still visible on a 4 GB device', () async {
      final models = await ModelService.getAvailableModels(ramGB: 4);
      expect(models.length, ModelService.getAllModels().length);
    });

    test('larger devices retain their recommended models', () async {
      expect(await ModelService.getRecommendedModels(ramGB: 16), hasLength(5));
    });
  });

  group('ModelService.filterByRam', () {
    final models = ModelService.getAllModels();

    test('keeps only Nomad Nano on a 2GB device', () {
      final filtered = ModelService.filterByRam(models, 2);
      expect(filtered.map((m) => m.id), ['nomad-nano-lfm25-450m']);
    });

    test('keeps Nomad Nano and Nomad Lite on a 3GB device', () {
      final filtered = ModelService.filterByRam(models, 3);
      expect(filtered.map((m) => m.id), [
        'nomad-nano-lfm25-450m',
        'nomad-lite-qwen-3.5-0.8b',
      ]);
    });

    test('adds Nomad Steady on a 5GB device', () {
      final filtered = ModelService.filterByRam(models, 5);
      expect(filtered.map((m) => m.id), [
        'nomad-nano-lfm25-450m',
        'nomad-lite-qwen-3.5-0.8b',
        'nomad-steady-lfm25-3b',
      ]);
    });

    test('exposes four models on a 7GB device', () {
      final filtered = ModelService.filterByRam(models, 7);
      expect(filtered, hasLength(4));
    });

    test('exposes all five models on a 16GB+ device', () {
      final filtered = ModelService.filterByRam(models, 16);
      expect(filtered, hasLength(5));
    });

    test('returns an empty list for a device with no compatible models', () {
      final filtered = ModelService.filterByRam(models, 1);
      expect(filtered, isEmpty);
    });

    test('does not mutate the input list', () {
      final original = List.of(models);
      ModelService.filterByRam(models, 3);
      expect(models.map((m) => m.id), original.map((m) => m.id));
    });
  });

  group('ModelService.getAllModels', () {
    test('exposes the five-model Nomad lineup', () {
      final models = ModelService.getAllModels();
      expect(models, hasLength(5));
      expect(models.every((m) => m.id.startsWith('nomad-')), isTrue);
    });

    test('configures Nomad Steady as LFM 2.5 VL 3B', () {
      final models = ModelService.getAllModels();
      final steady = models.firstWhere((m) => m.id == 'nomad-steady-lfm25-3b');
      expect(steady.name, 'Nomad Steady');
      expect(steady.baseModel, 'LFM 2.5 VL 3B (Q4_0)');
      expect(steady.requiredRAM, 5);
      expect(steady.sizeMB, 1594);
      expect(steady.totalBytes, 1593894944);
      expect(
        ModelService.getDownloadUrl('nomad-steady-lfm25-3b'),
        'https://huggingface.co/LiquidAI/LFM2.5-VL-3B-GGUF/resolve/main/LFM2.5-VL-3B-Q4_0.gguf',
      );
      expect(
        ModelService.getMmprojUrl('nomad-steady-lfm25-3b'),
        'https://huggingface.co/LiquidAI/LFM2.5-VL-3B-GGUF/resolve/main/mmproj-LFM2.5-VL-3B-Q8_0.gguf',
      );
      expect(
        ModelService.repoFor('nomad-steady-lfm25-3b'),
        'LiquidAI/LFM2.5-VL-3B-GGUF',
      );
      expect(
        ModelService.filenameFor('nomad-steady-lfm25-3b'),
        'LFM2.5-VL-3B-Q4_0.gguf',
      );
      expect(
        ModelService.pinnedSha256For('nomad-steady-lfm25-3b'),
        '364224c6bd45b4ff4bf8af71f7be384ea166fa0f573d68bc0b6e10ef9ae7ae58',
      );
      expect(
        ModelService.pinnedMmprojSha256For('nomad-steady-lfm25-3b'),
        'ecbbe7097f696dba67172738d79c9f01132cdb6c0b457606315e268df3d67e64',
      );
    });
  });
}
