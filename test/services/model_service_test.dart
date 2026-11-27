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
    test('exposes the five-model Nomad lineup', () {
      final models = ModelService.getAllModels();
      expect(models, hasLength(5));
      expect(models.every((m) => m.id.startsWith('nomad-')), isTrue);
    });

    test('configures Nomad Omni as LFM3-Omni-2B', () {
      final omni = ModelService.getAllModels()
          .firstWhere((m) => m.id == 'nomad-omni-lfm3-2b');
      expect(omni.name, 'Nomad Omni');
      expect(omni.baseModel, 'LFM3 Omni 2B (Q4_K_M)');
      expect(omni.requiredRAM, 6);
      expect(omni.sizeMB, 1049);
      expect(omni.totalBytes, 1099630080);
      expect(omni.capabilities, containsAll(['vision', 'omni']));
      expect(
        ModelService.getDownloadUrl('nomad-omni-lfm3-2b'),
        'https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF/resolve/main/LFM3-Omni-2B-Q4_K_M.gguf',
      );
      expect(
        ModelService.getMmprojUrl('nomad-omni-lfm3-2b'),
        'https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF/resolve/main/mmproj-LFM3-Omni-2B-Q8_0.gguf',
      );
      expect(
        ModelService.repoFor('nomad-omni-lfm3-2b'),
        'LiquidAI/LFM3-Omni-2B-GGUF',
      );
      expect(
        ModelService.filenameFor('nomad-omni-lfm3-2b'),
        'LFM3-Omni-2B-Q4_K_M.gguf',
      );
      expect(
        ModelService.pinnedSha256For('nomad-omni-lfm3-2b'),
        '9f8d30e9d4fd7a9349d586e077988229b3ca0a0e4ad730897563d1eccc9893e2',
      );
      expect(
        ModelService.pinnedMmprojSha256For('nomad-omni-lfm3-2b'),
        '8a25f9d1931244429de404fccacfb7fb933970a36aa5688d2f5069f29c6b27b1',
      );
      expect(ModelService.supportsAudio('nomad-omni-lfm3-2b'), isTrue);
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
