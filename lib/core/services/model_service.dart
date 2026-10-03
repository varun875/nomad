import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/hf_model.dart';
import 'device_info_service.dart';

class ModelService {
  static const _channel = MethodChannel('com.varun.nomad/storage');

  /// Desktop models are shared with the standalone Nomad Code server at
  /// Documents/Nomad/models. Mobile models remain private to the app.
  static Future<Directory> getModelDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return Directory('${documents.path}/${isDesktop ? 'Nomad/models' : 'models'}');
  }

  // Nomad lineup (Unsloth GGUF quantizations & Liquid AI)
  static final List<HFModel> _allModels = [
    HFModel(
      id: 'nomad-nano-lfm25-450m',
      name: 'Nomad Nano',
      baseModel: 'LFM 2.5 VL 450M',
      description: 'Ultra-compact vision-language model by Liquid AI. Sub-250ms visual understanding, OCR, and chat. Runs effortlessly on 2GB RAM devices.',
      sizeMB: 229,
      totalBytes: 229313568,
      requiredRAM: 2,
      speed: 5.5,
      quality: 4.0,
      capabilities: ['chat', 'vision', 'speed', 'low-ram'],
    ),
    HFModel(
      id: 'nomad-lite-qwen-3.5-0.8b',
      name: 'Nomad Lite',
      baseModel: 'Qwen 3.5 0.8B',
      description: 'Ultra-lightweight vision model under 1B parameters. Fast inference with image understanding. Perfect for devices with limited RAM.',
      sizeMB: 533,
      requiredRAM: 3,
      speed: 5.0,
      quality: 4.0,
      capabilities: ['chat', 'vision', 'speed', 'low-ram'],
    ),
    HFModel(
      id: 'nomad-steady-gemma4-e2b',
      name: 'Nomad Steady',
      baseModel: 'Gemma 4 E2B QAT',
      description: 'Mobile-optimized Gemma 4 E2B with image understanding. QAT mobile quantization uses targeted 2-bit layers to reduce storage and memory while retaining strong quality on phones.',
      sizeMB: 2186,
      totalBytes: 2186186784,
      requiredRAM: 5,
      speed: 4.2,
      quality: 4.6,
      capabilities: ['chat', 'vision', 'reasoning', 'balanced'],
    ),
    HFModel(
      id: 'nomad-smart-gemma4-e4b',
      name: 'Nomad Smart',
      baseModel: 'Gemma 4 E4B (e1)',
      description: 'Finn Technologies e1 - a fine-tuned Gemma 4 E4B with advanced reasoning across math, physics, CS, biology, chemistry, philosophy, and linguistics. Excels at complex multimodal understanding and deep analysis.',
      sizeMB: 5300,
      totalBytes: 5302272800,
      requiredRAM: 7,
      speed: 3.5,
      quality: 5.0,
      capabilities: ['chat', 'vision', 'expert', 'reasoning', 'creative'],
    ),
    HFModel(
      id: 'nomad-pro-mimo26-9b',
      name: 'Nomad Pro',
      baseModel: 'MiMo 2.6 Flash 9B Q4',
      description: 'Xiaomi MiMo V2.6 Distill 9B - an agentic powerhouse distilled from MiMo-V2.6-Flash. Excels at coding, tool use, multi-step reasoning, and long-horizon tasks. Requires 16GB RAM.',
      sizeMB: 5975,
      totalBytes: 6270652252,
      requiredRAM: 16,
      speed: 2.5,
      quality: 5.5,
      capabilities: ['chat', 'expert', 'reasoning', 'coding', 'agentic', 'tools'],
    ),
  ];

  static Future<int> getDeviceRAM() => DeviceInfo.deviceRamGB();

  static Future<Map<String, int>> getStorageSpace() async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final result = await _channel.invokeMethod('getStorageSpace');
        final total = (result['total'] as int);
        final free = (result['free'] as int);
        return {'total': total, 'free': free};
      } catch (_) {
        return {'total': 0, 'free': 0};
      }
    }
    return _getDesktopStorage();
  }

  static Future<Map<String, int>> _getDesktopStorage() async {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        final home = Platform.environment['HOME'] ?? '/';
        final result = await Process.run('df', ['-B1', home]);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().split('\n');
          if (lines.length > 1) {
            final parts = lines[1].split(RegExp(r'\s+'));
            if (parts.length >= 4) {
              final total = int.tryParse(parts[1]);
              final used = int.tryParse(parts[2]);
              final avail = int.tryParse(parts[3]);
              if (total != null && avail != null) {
                return {'total': total, 'free': avail};
              }
              if (total != null && used != null) {
                return {'total': total, 'free': total - used};
              }
            }
          }
        }
      }
      if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-Command',
          r"Get-CimInstance Win32_LogicalDisk -Filter 'DeviceID=''C:''' | ForEach-Object { '{0} {1}' -f $_.FreeSpace, $_.Size }"
        ]);
        if (result.exitCode == 0) {
          final parts = result.stdout.toString().trim().split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            final free = int.tryParse(parts[0]);
            final total = int.tryParse(parts[1]);
            if (total != null && free != null) {
              return {'total': total, 'free': free};
            }
          }
        }
      }
    } catch (_) {}
    return {'total': 0, 'free': 0};
  }

  /// Pure RAM filter used by [getAvailableModels]. Unit-testable without
  /// touching platform channels.
  ///
  /// 2GB: Nomad Nano
  /// 3GB: Nomad Nano + Nomad Lite
  /// 5GB: Nomad Nano + Nomad Lite + Nomad Steady (Gemma 4 E2B QAT)
  /// 7GB: Nomad Nano + Nomad Lite + Nomad Steady + Nomad Smart
  /// 16GB+: All models including Nomad Pro
  static List<HFModel> filterByRam(List<HFModel> models, int ramGB) {
    return models.where((m) => m.requiredRAM <= ramGB).toList();
  }

  /// Get models available for the device's RAM.
  ///
  /// Desktop always has enough RAM for these small models; filtering is only
  /// relevant on mobile. [ramGB] can be injected for testing/preview.
  static Future<List<HFModel>> getAvailableModels({int? ramGB}) async {
    // Keep every model visible so users can explicitly test the limits of
    // their device. The pure filterByRam helper remains available for tests.
    return List.from(_allModels);
  }

  /// Alias for getAvailableModels - used by UI components
  static Future<List<HFModel>> getRecommendedModels() async {
    return getAvailableModels();
  }

  /// Get all models (for settings/models page)
  static List<HFModel> getAllModels() => List.from(_allModels);

  static String getDownloadUrl(String modelId) {
    switch (modelId) {
      case 'nomad-nano-lfm25-450m':
        return 'https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/LFM2.5-VL-450M-Q4_K_M.gguf';
      case 'nomad-lite-qwen-3.5-0.8b':
        return 'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf';
      case 'nomad-steady-gemma4-e2b':
        return 'https://huggingface.co/unsloth/gemma-4-E2B-it-qat-mobile-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf';
      case 'nomad-smart-gemma4-e4b':
        return 'https://huggingface.co/Finn-Technologies/e1/resolve/main/e1.Q4_K_M.gguf';
      case 'nomad-pro-mimo26-9b':
        return 'https://huggingface.co/bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF/resolve/main/MiMo-V2.6-Distill-Qwen-9B-Q4_K_M.gguf';
      default:
        return '';
    }
  }

  static String? getMmprojUrl(String modelId) {
    switch (modelId) {
      case 'nomad-nano-lfm25-450m':
        return 'https://huggingface.co/LiquidAI/LFM2.5-VL-450M-GGUF/resolve/main/mmproj-LFM2.5-VL-450m-Q8_0.gguf';
      case 'nomad-lite-qwen-3.5-0.8b':
        return 'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/mmproj-F16.gguf';
      case 'nomad-steady-gemma4-e2b':
        return 'https://huggingface.co/unsloth/gemma-4-E2B-it-qat-mobile-GGUF/resolve/main/mmproj-F16.gguf';
      case 'nomad-smart-gemma4-e4b':
        return 'https://huggingface.co/Finn-Technologies/e1/resolve/main/mmproj-e1.gguf';
      case 'nomad-pro-mimo26-9b':
        return 'https://huggingface.co/bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF/resolve/main/mmproj-MiMo-V2.6-Distill-Qwen-9B-f16.gguf';
      default:
        return null;
    }
  }

  /// Whether the model requires a HuggingFace auth token to download
  static bool modelNeedsAuth(String modelId) => false;

  static String _repoFor(String modelId) {
    switch (modelId) {
      case 'nomad-nano-lfm25-450m':
        return 'LiquidAI/LFM2.5-VL-450M-GGUF';
      case 'nomad-lite-qwen-3.5-0.8b':
        return 'unsloth/Qwen3.5-0.8B-GGUF';
      case 'nomad-steady-gemma4-e2b':
        return 'unsloth/gemma-4-E2B-it-qat-mobile-GGUF';
      case 'nomad-smart-gemma4-e4b':
        return 'Finn-Technologies/e1';
      case 'nomad-pro-mimo26-9b':
        return 'bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF';
      default:
        return '';
    }
  }

  static String _filenameFor(String modelId) {
    switch (modelId) {
      case 'nomad-nano-lfm25-450m':
        return 'LFM2.5-VL-450M-Q4_K_M.gguf';
      case 'nomad-lite-qwen-3.5-0.8b':
        return 'Qwen3.5-0.8B-Q4_K_M.gguf';
      case 'nomad-steady-gemma4-e2b':
        return 'gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf';
      case 'nomad-smart-gemma4-e4b':
        return 'e1.Q4_K_M.gguf';
      case 'nomad-pro-mimo26-9b':
        return 'MiMo-V2.6-Distill-Qwen-9B-Q4_K_M.gguf';
      default:
        return '';
    }
  }

  /// SHA-256 of each downloadable model file, pinned in the app binary.
  ///
  /// These are the *only* trusted checksums. They must never be fetched from
  /// the network at download time: the file and its expected hash would then
  /// come from the same host, letting a tampered repo or MITM satisfy its own
  /// verification. Obtained from each HuggingFace repo's LFS metadata.
  static const _pinnedSha256 = <String, String>{
    'nomad-nano-lfm25-450m':
        '1093f1331319199bbcacdbd7ecc9aa6e5678db6b55073948d0f508be90c8ab68',
    'nomad-lite-qwen-3.5-0.8b':
        'bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517',
    'nomad-steady-gemma4-e2b':
        '0a5bbc20f91f92da96ab4870fa71b356c45b8500a7b8b9c3e0eb48359b72da28',
    'nomad-smart-gemma4-e4b':
        'f70cff4e2c80b68872446a5e87715d84eb1d080f8cea3b73f3802535f8c36782',
    'nomad-pro-mimo26-9b':
        '4bca6f18c73f72270c7a20c2ea2bea581de8246e318714277120369d34048c81',
  };

  /// SHA-256 of each multimodal projector (mmproj) GGUF, downloaded alongside
  /// its model. Pinned for the same reason as [_pinnedSha256].
  static const _pinnedMmprojSha256 = <String, String>{
    'nomad-nano-lfm25-450m':
        'ebfc428baa37efad8bae93864f914b2634a09009f91ad59f974fe1a1565d8561',
    'nomad-lite-qwen-3.5-0.8b':
        '56e4c6cfe73b0c82e3e82bc518d7591997e61d81f723fc41a586f4fa69ea2453',
    'nomad-steady-gemma4-e2b':
        '13c8966d1635d02e6727f27402880614906fa291850c07feda18dbcddf2291b6',
    'nomad-smart-gemma4-e4b':
        '0d59fc5ceca55f0a3f5398ceaca87349597bdae2597b23619c435f164a0c0c52',
    'nomad-pro-mimo26-9b':
        'ff348f3180a63188aa7285db85f550fe38acb61dd013c599eb8bad08d2cc2576',
  };

  static String? pinnedSha256For(String modelId) => _pinnedSha256[modelId];

  static String? pinnedMmprojSha256For(String modelId) =>
      _pinnedMmprojSha256[modelId];

  static String repoFor(String modelId) => _repoFor(modelId);
  static String filenameFor(String modelId) => _filenameFor(modelId);
}
