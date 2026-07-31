import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/model_service.dart';

void main() {
  group('ModelService.filterByRam', () {
    final models = ModelService.getAllModels();

    test('keeps only Nomad Lite on a 3GB device', () {
      final filtered = ModelService.filterByRam(models, 3);
      expect(filtered.map((m) => m.id), ['nomad-lite-qwen-3.5-0.8b']);
    });

    test('adds Nomad Steady on a 5GB device', () {
      final filtered = ModelService.filterByRam(models, 5);
      expect(filtered.map((m) => m.id), [
        'nomad-lite-qwen-3.5-0.8b',
        'nomad-steady-gemma4-e2b',
      ]);
    });

    test('exposes all models on a 7GB+ device', () {
      final filtered = ModelService.filterByRam(models, 7);
      expect(filtered, hasLength(3));
    });

    test('returns an empty list for a device with no compatible models', () {
      final filtered = ModelService.filterByRam(models, 2);
      expect(filtered, isEmpty);
    });

    test('does not mutate the input list', () {
      final original = List.of(models);
      ModelService.filterByRam(models, 3);
      expect(models.map((m) => m.id), original.map((m) => m.id));
    });
  });

  group('ModelService.getAllModels', () {
    test('exposes the three-model Nomad lineup', () {
      final models = ModelService.getAllModels();
      expect(models, hasLength(3));
      expect(models.every((m) => m.id.startsWith('nomad-')), isTrue);
    });
  });
}
