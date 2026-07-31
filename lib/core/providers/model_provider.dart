import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/hf_model.dart';
import 'download_provider.dart';

final selectedModelIdProvider = StateNotifierProvider<SelectedModelIdNotifier, String?>((ref) {
  return SelectedModelIdNotifier();
});

class SelectedModelIdNotifier extends StateNotifier<String?> {
  SelectedModelIdNotifier() : super(null) {
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('selectedModelId');
    if (savedId != null && mounted) {
      state = savedId;
    }
  }

  Future<void> select(String? modelId) async {
    state = modelId;
    final prefs = await SharedPreferences.getInstance();
    if (modelId != null) {
      await prefs.setString('selectedModelId', modelId);
    } else {
      await prefs.remove('selectedModelId');
    }
  }
}

final selectedModelProvider = Provider<HFModel?>((ref) {
  final selectedId = ref.watch(selectedModelIdProvider);
  final downloadedModels = ref.watch(downloadProvider);

  // If a specific model is selected, return it
  if (selectedId != null) {
    for (final model in downloadedModels) {
      if (model.id == selectedId) return model;
    }
  }

  // Auto-select the first downloaded model if none is selected
  final installed = downloadedModels.where((m) => m.downloaded).toList();
  if (installed.isNotEmpty) {
    // Persist the auto-selection so it sticks on next launch
    if (selectedId == null) {
      Future.microtask(() => ref.read(selectedModelIdProvider.notifier).select(installed.first.id));
    }
    return installed.first;
  }

  return null;
});
