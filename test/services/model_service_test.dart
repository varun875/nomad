import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/model_service.dart';

void main() {
  group('ModelService recommendations', () {
    test('4 GB onboarding recommends Lite and Steady', () async {
      final models = await ModelService.getRecommendedModels(ramGB: 4);
      expect(models.map((model) => model.name),
          ['Nomad Lite', 'Nomad Steady']);
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

    test('keeps no models on a 2GB device', () {
      final filtered = ModelService.filterByRam(models, 2);
      expect(filtered, isEmpty);
    });

    test('keeps Nomad Lite on a 3GB device', () {
      final filtered = ModelService.filterByRam(models, 3);
      expect(filtered.map((m) => m.id), ['nomad-lite-qwen-3.5-0.8b']);
    });

    test('adds Nomad Steady on a 4GB device', () {
      final filtered = ModelService.filterByRam(models, 4);
      expect(filtered.map((m) => m.id), [
        'nomad-lite-qwen-3.5-0.8b',
        'nomad-steady-lfm3-2b',
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
    test('exposes the four-model Nomad lineup', () {
      final models = ModelService.getAllModels();
      expect(models, hasLength(4));
      expect(models.every((m) => m.id.startsWith('nomad-')), isTrue);
    });

    test('configures Nomad Pro as Ternary Bonsai 2.5', () {
      final pro = ModelService.getAllModels()
          .firstWhere((m) => m.id == 'nomad-pro-bonsai25-27b');
      expect(pro.name, 'Nomad Pro');
      expect(pro.baseModel, 'Ternary Bonsai 2.5 27B (Q2_0)');
      expect(pro.requiredRAM, 16);
      expect(pro.sizeMB, 7319);
      expect(pro.totalBytes, 7673194848);
      expect(pro.capabilities, containsAll(['expert', 'agentic']));
      expect(
        ModelService.getDownloadUrl('nomad-pro-bonsai25-27b'),
        'https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-GGUF/resolve/main/Ternary-Bonsai-2.5-27B-Q2_0.gguf',
      );
      expect(
        ModelService.getMmprojUrl('nomad-pro-bonsai25-27b'),
        'https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-GGUF/resolve/main/Ternary-Bonsai-2.5-27B-mmproj-Q8_0.gguf',
      );
      expect(
        ModelService.repoFor('nomad-pro-bonsai25-27b'),
        'prism-ml/Ternary-Bonsai-2.5-27B-GGUF',
      );
      expect(
        ModelService.filenameFor('nomad-pro-bonsai25-27b'),
        'Ternary-Bonsai-2.5-27B-Q2_0.gguf',
      );
      expect(
        ModelService.pinnedSha256For('nomad-pro-bonsai25-27b'),
        '84496171ca79d4d33fb45612a2afd8303ec494baf916281023b7dc9cb3b3b9fa',
      );
      expect(
        ModelService.pinnedMmprojSha256For('nomad-pro-bonsai25-27b'),
        '6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903',
      );
      expect(ModelService.supportsAudio('nomad-steady-lfm3-2b'), isFalse);
    });

    test('configures Nomad Steady as LFM3-VL-2B', () {
      final models = ModelService.getAllModels();
      final steady = models.firstWhere((m) => m.id == 'nomad-steady-lfm3-2b');
      expect(steady.name, 'Nomad Steady');
      expect(steady.baseModel, 'LFM3-VL-2B (QAD Q4_0)');
      expect(steady.requiredRAM, 4);
      expect(steady.sizeMB, 1001);
      expect(steady.totalBytes, 1049615648);
      expect(steady.mmprojBytes, 203031872);
      expect(
        ModelService.getDownloadUrl('nomad-steady-lfm3-2b'),
        'https://huggingface.co/LiquidAI/LFM3-VL-2B-GGUF/resolve/main/LFM3-VL-2B-QAD-Q4_0.gguf',
      );
      expect(
        ModelService.getMmprojUrl('nomad-steady-lfm3-2b'),
        'https://huggingface.co/LiquidAI/LFM3-VL-2B-GGUF/resolve/main/mmproj-LFM3-VL-2B-Q8_0.gguf',
      );
      expect(
        ModelService.repoFor('nomad-steady-lfm3-2b'),
        'LiquidAI/LFM3-VL-2B-GGUF',
      );
      expect(
        ModelService.filenameFor('nomad-steady-lfm3-2b'),
        'LFM3-VL-2B-QAD-Q4_0.gguf',
      );
      expect(
        ModelService.pinnedSha256For('nomad-steady-lfm3-2b'),
        '621c455376cb96a20891697deb9975c6fb47dd5ea98ed3ad1f3b7e8f24f0b1e6',
      );
      expect(
        ModelService.pinnedMmprojSha256For('nomad-steady-lfm3-2b'),
        'c5c5b58d544a18da919172d2d0368090ea1a4a351b6feb7f8a326a264a5918ab',
      );
    });
  });
}
