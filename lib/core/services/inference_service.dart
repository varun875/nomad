import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_info_service.dart';
import 'model_service.dart';
import 'performance_service.dart';
import '../utils/logger.dart';
import '../utils/pre_load_cleanup.dart';

class InferenceService {
  static const generationThreadsPreference = 'inferenceGenerationThreads';

  /// SharedPreferences key counting in-flight native model loads. A counter
  /// left behind means the process died mid-load (typically an OOM kill during
  /// auto-restore); two in a row mark a crash loop so startup can fall back to
  /// a small model instead of dying again. Cleared on load success or a
  /// handled load failure.
  static const loadCrashGuardKey = 'modelLoadCrashGuard';
  static final InferenceService _instance = InferenceService._internal();
  factory InferenceService() => _instance;
  InferenceService._internal({
    LlamaEngine Function()? engineFactory,
    bool? mobile,
    Future<int> Function()? readRam,
    Future<DeviceMemory?> Function()? readMemory,
  })  : _engineFactory = engineFactory ?? (() => LlamaEngine(LlamaBackend())),
        _isMobile = mobile ?? (Platform.isAndroid || Platform.isIOS),
        _readRam = readRam ?? ModelService.getDeviceRAM,
        _readMemory = readMemory ?? DeviceInfo.memorySnapshot {
    unawaited(LlamaLogging.configure(level: LlamaLogLevel.none));
  }

  @visibleForTesting
  InferenceService.forTesting({
    required LlamaEngine Function() engineFactory,
    int ramGB = 4,
    bool mobile = true,
    Future<DeviceMemory?> Function()? readMemory,
  }) : this._internal(
          engineFactory: engineFactory,
          mobile: mobile,
          readRam: () async => ramGB,
          readMemory: readMemory ?? (() async => null),
        );

  final LlamaEngine Function() _engineFactory;
  final bool _isMobile;
  final Future<int> Function() _readRam;
  final Future<DeviceMemory?> Function() _readMemory;
  LlamaEngine? _engine;
  String? _loadedModelPath;
  String? _availableMmProjPath;
  String? _loadedMmProjPath;
  bool _lowRamModel = false;
  bool _releaseProjectorAfterTurn = false;
  bool _generating = false;
  bool _releaseRequested = false;
  Future<void> _modelLifecycle = Future<void>.value();

  bool get isGenerating => _generating;

  double _lastPromptTokPerSec = 0;
  double _lastOutputTokPerSec = 0;
  int _lastPromptTokens = 0;
  int _lastOutputTokens = 0;

  double get lastPromptTokPerSec => _lastPromptTokPerSec;
  double get lastOutputTokPerSec => _lastOutputTokPerSec;
  int get lastPromptTokens => _lastPromptTokens;
  int get lastOutputTokens => _lastOutputTokens;

  bool get isLoaded => _engine != null && _loadedModelPath != null;

  /// The raw engine when a model is loaded. Used by [Lfm3TtsService] to
  /// attach `TextToSpeechEngine` without a second model load.
  LlamaEngine? get engine => _engine;

  /// Whether the loaded model is the audio-capable Omni model.
  bool get isOmniLoaded =>
      _loadedModelPath != null &&
      _loadedModelPath!.replaceAll('\\', '/').contains('nomad-omni');

  String? get modelName =>
      _loadedModelPath?.split('/').last.replaceAll('.gguf', '');

  String? get modelPath => _loadedModelPath;

  int get contextSize => _contextSize ?? 2048;
  int? _contextSize;

  /// Detect optimal GPU layers for the current device.
  /// On desktop with sufficient RAM (8GB+), offload some layers to GPU.
  /// On mobile and low-RAM desktops, keep all layers on CPU.
  /// The layer counts are intentionally higher than most model architectures;
  /// llama.cpp safely clamps to the actual layer count of the loaded model.
  static int _detectOptimalGpuLayers() {
    if (Platform.isAndroid || Platform.isIOS) return 0;
    final totalMem = DeviceInfo.totalMemoryMB();
    if (totalMem == null) return 0;
    // 8GB+ RAM: aggressive GPU offload (safe upper bound, clamped by engine)
    if (totalMem >= 8192) return 33;
    // 6-8GB RAM: conservative GPU offload
    if (totalMem >= 6000) return 16;
    return 0;
  }

  /// Count the "performance" (big) cores for a map of physical CPU index ->
  /// max frequency in kHz. A core counts as performance when it runs within
  /// 90% of the fastest core on the chip (e.g. Dimensity 6300: A76 @ 2.4GHz
  /// counts, A55 @ 2.0GHz at ~83% does not). Pure and unit-testable.
  static int countPerformanceCores(Map<int, int> cpuMaxFreqKhz) {
    if (cpuMaxFreqKhz.isEmpty) return 0;
    final frequencies = cpuMaxFreqKhz.values.toList()
      ..sort((a, b) => b.compareTo(a));
    final peak = frequencies.first;
    if (peak <= 0) return 0;
    return frequencies.where((f) => f * 10 >= peak * 9).length;
  }

  /// Best-effort read of per-CPU max frequencies on Android via sysfs.
  /// Returns null when unavailable (non-Android or sandboxed) so callers fall
  /// back to the total processor count. The scan is cached: the sysfs walk is
  /// synchronous disk I/O and must not repeat on every model load.
  static Map<int, int>? _cachedMaxCpuFrequencies;

  static Map<int, int>? _readMaxCpuFrequencies() {
    if (_cachedMaxCpuFrequencies != null) return _cachedMaxCpuFrequencies;
    if (!Platform.isAndroid) return null;
    try {
      final result = <int, int>{};
      for (var i = 0; i < 128; i++) {
        final cpuDir = Directory('/sys/devices/system/cpu/cpu$i');
        if (!cpuDir.existsSync()) {
          if (result.isNotEmpty) break;
          continue;
        }
        final freqFile = File(
          '/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq',
        );
        if (freqFile.existsSync()) {
          final value = int.tryParse(freqFile.readAsStringSync().trim());
          if (value != null && value > 0) {
            result[i] = value;
          }
        }
      }
      _cachedMaxCpuFrequencies = result.isEmpty ? null : result;
      return _cachedMaxCpuFrequencies;
    } catch (_) {
      _cachedMaxCpuFrequencies = null;
      return null;
    }
  }

  /// Resolve the generation thread count from the performance-core count and
  /// the platform processor count. Pure and unit-testable so every chip
  /// topology can be verified off-device.
  ///
  /// When [performanceCores] is known (Android sysfs), use the performance
  /// cores plus a small number of efficiency cores. On hybrid mobile CPUs,
  /// limiting decode to only the fast cores can leave too much compute unused;
  /// using every core can starve Flutter and increase thermal throttling. The
  /// 2+6 Dimensity layout therefore starts at four threads, while larger
  /// performance clusters can use more. Without detection it falls back to a
  /// processor-derived estimate that reserves headroom for Flutter's UI/raster
  /// threads.
  static int resolveOptimalThreads({
    required bool constrained,
    required int processors,
    int? performanceCores,
  }) {
    if (performanceCores != null && performanceCores > 0) {
      // Small performance clusters benefit from two additional efficiency
      // workers. This gives a 2+6 layout four decode threads, while a phone
      // with four or more performance cores stays on that cluster and avoids
      // oversubscribing the CPU.
      final hybridTarget = performanceCores == 1
          ? 2
          : (performanceCores == 2 ? 4 : performanceCores);
      return hybridTarget.clamp(2, processors).clamp(2, 8);
    }
    if (processors <= 2) return processors;
    final target = constrained ? processors - 2 : processors - 1;
    return target.clamp(2, constrained ? 4 : 8);
  }

  /// Resolve the thread count for prompt/batch evaluation. Unlike single-token
  /// decode, batched prompt eval parallelizes well across *all* cores — every
  /// thread works on an independent slice of the batch, so spreading it over
  /// big + little cores yields ~4-6x faster TTFT on big.LITTLE chips without
  /// triggering the MediaTek #21763 throughput collapse (which only hits
  /// per-token decode). Pure and unit-testable.
  static int resolveOptimalBatchThreads({required int processors}) {
    return processors.clamp(2, 16);
  }

  static int _optimalBatchThreads() {
    final processors = Platform.numberOfProcessors;
    final threads = resolveOptimalBatchThreads(processors: processors);
    Log.d(
      'Inference',
      'Batch threads (prompt eval): $processors cores -> $threads threads',
    );
    return threads;
  }

  static Future<int?> _generationThreadOverride() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(generationThreadsPreference);
    if (value == null || !const [2, 4, 6, 8].contains(value)) return null;
    return value;
  }

  /// Detects 32-bit ARMv7 native code from the process's loaded-library map.
  /// 64-bit ART loads libraries out of `/lib/arm64/` inside the APK, while
  /// 32-bit devices use `/lib/arm/`. ARMv7 has a far smaller L2 cache than
  /// modern arm64 chips, so callers shrink the native batch to fit it. When
  /// the markers are absent (unknown platform), defaults to 64-bit behavior.
  /// Pure and unit-testable.
  static bool classifiesAsArmv7(List<String> mapsLines) {
    for (final line in mapsLines) {
      if (line.contains('/lib/arm64/')) return false;
      if (line.contains('/lib/arm/')) return true;
    }
    return false;
  }

  static bool? _cachedArmv7;

  static bool _detectArmv7() {
    if (!Platform.isAndroid) return false;
    final cached = _cachedArmv7;
    if (cached != null) return cached;
    try {
      final detected = classifiesAsArmv7(
        File('/proc/self/maps').readAsLinesSync(),
      );
      _cachedArmv7 = detected;
      return detected;
    } catch (_) {
      _cachedArmv7 = false;
      return false;
    }
  }

  static int _optimalGenerationThreads(bool constrained) {
    int? performanceCores;
    if (Platform.isAndroid) {
      final frequencies = _readMaxCpuFrequencies();
      if (frequencies != null) {
        final detected = countPerformanceCores(frequencies);
        if (detected > 0) {
          performanceCores = detected;
        }
      }
    }
    final processors = Platform.numberOfProcessors;
    final threads = resolveOptimalThreads(
        constrained: constrained,
        processors: processors,
        performanceCores: performanceCores);
    Log.d(
      'Inference',
      'Threads: $performanceCores perf-cores/$processors cores -> $threads threads',
    );
    return threads;
  }

  Future<T> _withModelLifecycle<T>(Future<T> Function() action) {
    final result = _modelLifecycle.then((_) => action());
    // The caller gets the error; the queue itself must remain usable.
    _modelLifecycle =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<String> loadModel(String localPath) {
    if (_generating) {
      return Future.error(StateError(
          'Finish or stop the current response before loading another model.'));
    }
    return _withModelLifecycle(() => _loadModelInternal(localPath));
  }

  /// Conservative preflight estimates, not a promise that an allocation fits.
  /// mmap already defaults to on; weights still need resident working memory.
  static String? allocationError({
    required int ramGB,
    required int allocationBytes,
    int? requiredRAM,
    DeviceMemory? memory,
    bool projector = false,
  }) {
    if (ramGB > 4) return null;
    const mib = 1024 * 1024;
    if (!projector &&
        ((requiredRAM != null && requiredRAM > ramGB) ||
            allocationBytes > 1024 * mib)) {
      return 'This model is too large for the safe profile on a $ramGB GB phone. '
          'Choose Nomad Nano or Nomad Lite. Your downloaded file is kept.';
    }
    final reserve = (projector ? 256 : 512) * mib;
    if (memory != null &&
        (memory.lowMemory ||
            memory.availableBytes < allocationBytes + reserve)) {
      return projector
          ? 'Not enough free RAM for image processing. Close other apps, use Nomad Nano, or send text only.'
          : 'Not enough free RAM to load this model safely. Close other apps or choose Nomad Nano.';
    }
    return null;
  }

  Future<String> _loadModelInternal(String localPath) async {
    final stat = await File(localPath).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw Exception('Model file not found: $localPath');
    }

    if (_loadedModelPath == localPath && _engine != null) {
      return localPath;
    }

    final ram = _isMobile ? await _readRam() : 0;
    int? requiredRAM;
    final modelId =
        localPath.replaceAll('\\', '/').split('/').last.replaceAll('.gguf', '');
    for (final model in ModelService.getAllModels()) {
      if (model.id == modelId) requiredRAM = model.requiredRAM;
    }
    if (_isMobile) {
      final error = allocationError(
          ramGB: ram, allocationBytes: stat.size, requiredRAM: requiredRAM);
      if (error != null) throw StateError(error);
    }

    // Free the old context before allocating a replacement or checking free RAM.
    await _unloadModelInternal();
    if (_isMobile && ram <= 4) {
      final error = allocationError(
        ramGB: ram,
        allocationBytes: stat.size,
        requiredRAM: requiredRAM,
        memory: await _readMemory(),
      );
      if (error != null) throw StateError(error);
    }

    final fileSizeMB = stat.size ~/ (1024 * 1024);
    final mmProjPath = localPath.replaceAll('.gguf', '.mmproj');
    final hasVision = await File(mmProjPath).exists();

    // Dynamically scale context size based on platform and available RAM to optimize memory on mobile
    int ctx = 2048;
    if (_isMobile) {
      if (ram <= 4) {
        // 1536 keeps prompt-evaluation peaks (history + web_search tool
        // rounds) inside the safe profile on <= 4 GB phones.
        ctx = 1536;
      } else if (ram <= 8) {
        // 2500 keeps history (~1375 tokens) while saving ~150MB KV vs 3072
        // on 6GB mid-range phones (e.g. Steady 2.2GB on Dimensity 6300).
        ctx = fileSizeMB < 1000 ? 4096 : 2500;
      } else {
        // High-end mobile devices (12GB+ RAM): 4096 context for all models
        ctx = 4096;
      }
    } else {
      // Desktop platforms: keep high context size since there is plenty of memory and swap space
      ctx = fileSizeMB < 300 ? 4096 : (fileSizeMB < 1000 ? 6144 : 8192);
    }

    final gpuLayers = _isMobile ? 0 : _detectOptimalGpuLayers();

    // Configure model with optimized parameters:
    // - On mobile: enable Flash Attention and Q8_0 KV Cache quantization to reduce RAM by 50%
    final isMobile = _isMobile;
    final constrained = isMobile && ram <= 8;
    final lowEnd = isMobile && ram <= 4;
    final threadOverride = await _generationThreadOverride();
    final generationThreads =
        threadOverride ?? _optimalGenerationThreads(constrained);
    final batchThreads = _optimalBatchThreads();
    // 32-bit ARMv7 devices typically carry a ~256KB-1MB L2 per core; keep the
    // native batch small enough to stay resident instead of thrashing it.
    // Low-end (<= 4 GB) phones get the same n_batch = 64 profile to prevent
    // OOM spikes during web_search tool calls.
    final armv7 = Platform.isAndroid && _detectArmv7();
    // Large models on constrained (6-8GB) phones use the smaller 128/64
    // profile you requested - saves ~200MB peak during prefill vs 256/128.
    final isLargeConstrained = constrained && fileSizeMB >= 1000;
    final batchSize = armv7 || lowEnd
        ? 64
        : (isLargeConstrained ? 128 : (constrained ? 256 : 1024));
    final microBatchSize = armv7 || lowEnd
        ? 32
        : (isLargeConstrained ? 64 : (constrained ? 128 : 512));
    // Free render-side memory (image cache, idle creation webviews) before the
    // native allocation so the weights have the largest possible runway.
    PreLoadCleanup.run();

    final prefs = await SharedPreferences.getInstance();
    final loadCrashes = prefs.getInt(loadCrashGuardKey) ?? 0;
    // Persisted before the native load: a crash mid-load leaves the counter
    // behind, which is exactly what the guard must observe.
    await prefs.setInt(loadCrashGuardKey, loadCrashes + 1);

    final engine = _engineFactory();
    try {
      await engine.setModel(
        LlamaModel(ModelSource.path(localPath)),
        params: ModelParams(
          contextSize: ctx,
          gpuLayers: gpuLayers,
          // Prompt eval decodes a whole batch at once and parallelizes cleanly
          // across every core (big + little) for fast time-to-first-token, while
          // generation stays pinned to the big cores only: decode is bandwidth
          // bound and spilling to little cores both slows it and — on MediaTek —
          // can collapse throughput ~100x (llama.cpp #21763) and heat the chip.
          numberOfThreads: generationThreads,
          numberOfThreadsBatch: batchThreads,
          batchSize: batchSize,
          microBatchSize: microBatchSize,
          flashAttention:
              isMobile ? FlashAttention.enabled : FlashAttention.auto,
          cacheTypeK: isMobile ? KvCacheType.q8_0 : KvCacheType.f16,
          cacheTypeV: isMobile ? KvCacheType.q8_0 : KvCacheType.f16,
          // Keep weights mmapped so Android can page out cold tensors instead
          // of forcing resident allocations into lmkd; never mlock on mobile.
          useMmap: true,
          useMlock: false,
        ),
      );

      Log.d(
        'Inference',
        'Model loaded: ${localPath.split('/').last} (${fileSizeMB}MB) '
            'backend=${Platform.isAndroid ? 'cpu' : 'auto'} '
            'ctx=$ctx threads=$generationThreads'
            '${threadOverride == null ? '' : ' (override)'} '
            'batchThreads=$batchThreads '
            'batch=$batchSize ubatch=$microBatchSize gpuLayers=$gpuLayers '
            'fa=${isMobile ? 'on' : 'auto'} kv=q8_0 armv7=$armv7',
      );

      // On low-RAM phones the F16 vision encoder (~0.5-1GB) competes with the
      // model for memory even during text-only chats. Defer it until the first
      // image message instead of preloading it eagerly.
      String? availableMmProjPath;
      String? loadedMmProjPath;
      if (hasVision) {
        if (isMobile && constrained) {
          availableMmProjPath = mmProjPath;
        } else {
          await engine.loadMultimodalProjectorSource(
            ModelSource.path(mmProjPath),
          );
          loadedMmProjPath = mmProjPath;
        }
      }

      // Publish only a fully initialized engine; failed loads never look ready.
      _engine = engine;
      _availableMmProjPath = availableMmProjPath;
      _loadedMmProjPath = loadedMmProjPath;
      _loadedModelPath = localPath;
      _contextSize = ctx;
      _lowRamModel = lowEnd;
      // Release the projector after each turn on <= 6 GB phones instead of
      // keeping the vision encoder resident between messages.
      _releaseProjectorAfterTurn = _isMobile && ram <= 6;
      await prefs.setInt(loadCrashGuardKey, 0);
      return localPath;
    } catch (_) {
      // A handled failure is not a crash; roll the guard back.
      await prefs.setInt(loadCrashGuardKey, loadCrashes);
      try {
        await engine.dispose();
      } catch (error) {
        Log.e('Inference', 'Failed to clean up a model load', error);
      }
      rethrow;
    }
  }

  /// Pre-warm the engine by loading the model in the background.
  /// Call this on app start so the first message is near-instant.
  Future<void> warmUp(String modelId, {bool allowLowRam = false}) async {
    // Loads the last-used model in the background so it's ready. Startup
    // warm-up skips low-RAM phones; those pre-warm on chat open or input focus
    // via [allowLowRam] instead.
    try {
      if (!allowLowRam && _isMobile && await _readRam() <= 4) return;
      final directory = await ModelService.getModelDirectory();
      final modelPath =
          '${directory.path}/${modelId.replaceAll('/', '_')}.gguf';
      if (await File(modelPath).exists()) {
        await loadModel(modelPath);
      }
    } catch (_) {
      // Silently ignore — inference will lazy-load if warmup fails
    }
  }

  /// A memory-pressure or settings request never disposes an active decode.
  Future<void> unloadModel() {
    _releaseRequested = true;
    if (_generating) return Future<void>.value();
    return _withModelLifecycle(() async {
      _releaseRequested = false;
      await _unloadModelInternal();
    });
  }

  Future<void> _unloadModelInternal() async {
    final engine = _engine;
    _engine = null;
    _loadedModelPath = null;
    _availableMmProjPath = null;
    _loadedMmProjPath = null;
    _contextSize = null;
    _lowRamModel = false;
    _releaseProjectorAfterTurn = false;
    await engine?.dispose();
  }

  Future<void> _finishGeneration() async {
    try {
      await _withModelLifecycle(() async {
        if (_releaseRequested) {
          _releaseRequested = false;
          await _unloadModelInternal();
        } else if (_releaseProjectorAfterTurn && _loadedMmProjPath != null) {
          final projector = _loadedMmProjPath;
          try {
            await _engine!.unloadMultimodalProjector();
            _loadedMmProjPath = null;
            _availableMmProjPath = projector;
          } catch (_) {
            // If projector cleanup fails, don't keep a partly freed engine.
            await _unloadModelInternal();
            rethrow;
          }
        }
      });
    } catch (error) {
      Log.e('Inference', 'Native resource cleanup failed', error);
    } finally {
      _generating = false;
      // Pressure may arrive while projector cleanup is awaiting native code.
      if (_releaseRequested) {
        try {
          await unloadModel();
        } catch (error) {
          Log.e('Inference', 'Deferred model cleanup failed', error);
        }
      }
    }
  }

  /// Create a completion stream from pre-built messages and tools.
  /// Used by NomadCodeAgent which manages its own conversation context.
  Stream<LlamaCompletionChunk>? createStream({
    required List<LlamaChatMessage> messages,
    List<ToolDefinition>? tools,
    required String localPath,
    double temp = 0.0,
  }) {
    try {
      if (_generating || _loadedModelPath != localPath || _engine == null) {
        return null;
      }

      const stopSequences = [
        "<|im_end|>",
        "<|endoftext|>",
      ];

      final params = GenerationParams(
        temp: temp,
        maxTokens: 4096,
        stopSequences: stopSequences,
        streamBatchTokenThreshold: 8,
        streamBatchByteThreshold: 512,
        reusePromptPrefix: true,
        penalty: 1.0,
      );

      Stream<LlamaCompletionChunk> run() async* {
        if (_generating) throw StateError('Another response is still running.');
        _generating = true;
        try {
          await _modelLifecycle;
          if (_loadedModelPath != localPath || _engine == null) {
            throw StateError('Load the selected model before generating.');
          }
          yield* _engine!.create(messages, params: params, tools: tools);
        } finally {
          await _finishGeneration();
        }
      }

      return run();
    } catch (e) {
      return null;
    }
  }

  /// Retain the newest conversation turns whose content fits within
  /// [maxChars], in chronological order. The newest turn is always kept even
  /// if it alone exceeds the budget, so the model never runs with empty
  /// context. Pure and unit-testable.
  static List<Map<String, String>> trimHistoryForContext(
    List<Map<String, String>> history,
    int maxChars,
  ) {
    if (history.isEmpty) return [];
    int historyChars = 0;
    final retained = <Map<String, String>>[];
    // Iterate from the newest turn so stale context is dropped first and the
    // most relevant recent messages are always kept.
    for (final turn in history.reversed) {
      final role = turn['role'] ?? 'user';
      final content = turn['content'] ?? '';
      // Include role tag overhead (~8 chars) so token estimate isn't under-counted for tools/roles.
      final turnChars = content.length + role.length + 8;
      if (retained.isNotEmpty && historyChars + turnChars > maxChars) {
        break;
      }
      historyChars += turnChars;
      retained.add({'role': role, 'content': content});
    }
    return retained.reversed.toList();
  }

  Stream<String> streamChat({
    required String modelId,
    required String prompt,
    String? localPath,
    String? systemPrompt,
    List<Map<String, String>> history = const [],
    int maxTokens = 4096,
    List<String>? imagePaths,
    List<String>? audioPaths,
    List<ToolDefinition>? tools,
    ThinkingBudget? thinkingBudget,
  }) async* {
    if (_generating) {
      yield 'Error: Another response is still running. Finish or stop it before sending again.';
      return;
    }
    _generating = true;
    try {
      if (localPath == null || !(await File(localPath).exists())) {
        yield "Error: Local model file not found at $localPath.";
        return;
      }
      await _withModelLifecycle(() => _loadModelInternal(localPath));

      if (_engine == null) {
        yield "Error: Failed to load model engine.";
        return;
      }

      // Load the projector lazily on low-RAM phones: the mmproj was deferred
      // at model load time and is only needed for media messages.
      final hasAudio = audioPaths != null && audioPaths.isNotEmpty;
      final hasImages = imagePaths != null && imagePaths.isNotEmpty;
      if (hasImages || hasAudio) {
        if (_lowRamModel && (imagePaths?.length ?? 0) > 1) {
          yield 'Error: Use one image at a time on a low-memory phone.';
          return;
        }
        final mmProjPath = localPath.replaceAll('.gguf', '.mmproj');
        final mediaAvailable = _availableMmProjPath != null ||
            _loadedMmProjPath != null ||
            await File(mmProjPath).exists();
        if (!mediaAvailable) {
          yield hasAudio
              ? "Error: The current model cannot hear audio. Switch to an audio-capable model such as Nomad Omni."
              : "Error: The current model does not support image input. Switch to a vision-capable model or remove the attached image.";
          return;
        }
        if (_availableMmProjPath != null && _loadedMmProjPath == null) {
          if (_lowRamModel) {
            final error = allocationError(
              ramGB: await _readRam(),
              allocationBytes: await File(_availableMmProjPath!).length(),
              memory: await _readMemory(),
              projector: true,
            );
            if (error != null) {
              yield 'Error: $error';
              return;
            }
          }
          await _engine!.loadMultimodalProjectorSource(
            ModelSource.path(_availableMmProjPath!),
          );
          _loadedMmProjPath = _availableMmProjPath;
        }
      }

      final messages = <LlamaChatMessage>[];

      final effectiveSystem = systemPrompt ??
          "You are Nomad, an on-device AI. Answer concisely. Stop after answering.";
      messages.add(LlamaChatMessage.fromText(
        role: LlamaChatRole.system,
        text: effectiveSystem,
      ));

      final maxHistoryChars = (contextSize * 3.5 * 0.55).round();
      final retainedHistory = trimHistoryForContext(history, maxHistoryChars);
      int historyChars = 0;
      for (final turn in retainedHistory) {
        final role = turn['role'] ?? 'user';
        final content = turn['content'] ?? '';
        historyChars += content.length + role.length + 8;
        messages.add(LlamaChatMessage.fromText(
          role: role == 'assistant'
              ? LlamaChatRole.assistant
              : LlamaChatRole.user,
          text: content,
        ));
      }

      if (hasImages || hasAudio) {
        final parts = <LlamaContentPart>[
          LlamaTextContent(prompt),
          for (final path in imagePaths ?? const <String>[])
            LlamaImageContent(path: path),
          for (final path in audioPaths ?? const <String>[])
            LlamaAudioContent(path: path),
        ];
        messages.add(LlamaChatMessage.withContent(
          role: LlamaChatRole.user,
          content: parts,
        ));
      } else {
        messages.add(LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: prompt,
        ));
      }

      // Include tool definition chars so estimate doesn't under-count agentic prompts.
      final toolChars = tools?.fold<int>(
              0, (s, t) => s + t.name.length + t.description.length + 16) ??
          0;
      final totalPromptChars =
          effectiveSystem.length + historyChars + prompt.length + toolChars;
      final estimatedPromptTokens = (totalPromptChars / 3.5).round();
      // Don't starve output to 64 when prompt already fills context - that
      // produces 64-token truncated junk that looksTruncated re-triggers.
      // Clamp but log so the caller can see context pressure in logcat.
      final rawAvailable = contextSize - estimatedPromptTokens - 128;
      if (rawAvailable < 64) {
        Log.d('Inference',
            'Context pressure: ctx=$contextSize prompt~$estimatedPromptTokens -> available clamped to 64 (history may be truncated)');
      }
      final availableOutputTokens = rawAvailable.clamp(64, maxTokens);

      const stopSequences = [
        "<|im_end|>",
        "<|endoftext|>",
      ];

      final lowEnd = _lowRamModel;
      final constrained = PerformanceService.instance.isConstrained;
      final baseParams = GenerationParams(
        temp: 0.0,
        maxTokens: availableOutputTokens,
        stopSequences: stopSequences,
        // Batch tokens before crossing the native -> Dart boundary. A
        // threshold of 1/1 flushed on every single token, which on low-end
        // devices spends more time marshalling and rebuilding the UI than
        // generating text. Small batches keep streaming visibly "live" while
        // dramatically cutting per-token overhead.
        streamBatchTokenThreshold: lowEnd ? 10 : (constrained ? 8 : 6),
        streamBatchByteThreshold: lowEnd ? 512 : (constrained ? 384 : 256),
        reusePromptPrefix: true,
        penalty: 1.0,
        thinkingBudget: thinkingBudget,
      );

      final stopwatch = Stopwatch()..start();
      final outputStopwatch = Stopwatch();
      // Count the complete streamed character payload and estimate tokens
      // once at the end. Rounding every small chunk independently can turn a
      // perfectly valid short chunk into zero tokens and hide the final speed
      // indicator.
      int outputChars = 0;
      _lastOutputTokPerSec = 0;
      _lastOutputTokens = 0;
      bool firstTokenEmitted = false;

      const maxToolRounds = 5;
      int consecutiveFailures = 0;

      for (int round = 0; round < maxToolRounds; round++) {
        final stream = _engine!.create(
          messages,
          params: baseParams,
          tools: tools,
        );

        List<LlamaCompletionChunkToolCall>? lastToolCalls;
        bool hasEmittedContent = false;

        await for (final chunk in stream) {
          for (final choice in chunk.choices) {
            if (choice.delta.content != null) {
              final text = choice.delta.content!;
              if (!firstTokenEmitted) {
                final ttftMs = stopwatch.elapsedMilliseconds;
                if (ttftMs > 0) {
                  _lastPromptTokPerSec =
                      estimatedPromptTokens / (ttftMs / 1000.0);
                  Log.d(
                    'Inference',
                    'TTFT ${ttftMs}ms '
                        '($estimatedPromptTokens prompt tokens -> '
                        '${_lastPromptTokPerSec.toStringAsFixed(1)} t/s)',
                  );
                }
                _lastPromptTokens = estimatedPromptTokens;
                firstTokenEmitted = true;
                outputStopwatch.start();
              }
              outputChars += text.length;
              yield text;
              hasEmittedContent = true;
            }
            if (choice.delta.toolCalls != null &&
                choice.delta.toolCalls!.isNotEmpty) {
              lastToolCalls = choice.delta.toolCalls;
            }
          }
        }

        if (!hasEmittedContent && !firstTokenEmitted) {
          final ttftMs = stopwatch.elapsedMilliseconds;
          if (ttftMs > 0) {
            _lastPromptTokPerSec = estimatedPromptTokens / (ttftMs / 1000.0);
          }
          _lastPromptTokens = estimatedPromptTokens;
          firstTokenEmitted = true;
        }

        // No tool calls — done
        if (lastToolCalls == null ||
            lastToolCalls.isEmpty ||
            tools == null ||
            tools.isEmpty) {
          break;
        }

        // Too many consecutive failures — give up
        if (consecutiveFailures >= 5) {
          yield '\n\n(Too many tool errors. Stopping.)';
          break;
        }

        // Add assistant message with the tool calls
        messages.add(LlamaChatMessage.withContent(
          role: LlamaChatRole.assistant,
          content: [
            for (final tc in lastToolCalls)
              LlamaToolCallContent(
                id: tc.id,
                name: tc.function?.name ?? 'unknown',
                arguments: tc.function?.arguments != null
                    ? jsonDecode(tc.function!.arguments!)
                        as Map<String, dynamic>
                    : {},
                rawJson: tc.function?.arguments ?? '{}',
              ),
          ],
        ));

        // Execute each tool call
        var anySuccess = false;
        for (final tc in lastToolCalls) {
          final toolName = tc.function?.name ?? 'unknown';
          final toolArgs = tc.function?.arguments ?? '{}';

          yield '\n> *Running $toolName...*\n';

          String result;
          try {
            final def = tools.firstWhere(
              (t) => t.name == toolName,
              orElse: () => throw Exception('Unknown tool: $toolName'),
            );
            final args = jsonDecode(toolArgs) as Map<String, dynamic>;
            final raw = await def.invoke(args);
            result = raw?.toString() ?? '(no output)';
            anySuccess = true;
          } catch (e) {
            result = 'Error: $e';
          }

          // Show truncated result
          final short = result.length > 400
              ? '${result.substring(0, 400)}\n... (truncated)'
              : result;
          yield '$short\n';

          messages.add(LlamaChatMessage.withContent(
            role: LlamaChatRole.tool,
            content: [
              LlamaToolResultContent(
                id: tc.id,
                name: toolName,
                result: result,
              ),
            ],
          ));
        }

        consecutiveFailures = anySuccess ? 0 : consecutiveFailures + 1;
      }

      // Output speed should measure decode time only. The full stopwatch also
      // includes prompt evaluation/TTFT, which makes fast decoders look slow
      // whenever the conversation history is long.
      final elapsedMs = outputStopwatch.elapsedMilliseconds;
      final tokenCount =
          outputChars == 0 ? 0 : (outputChars / 3.5).round().clamp(1, 1 << 31);
      if (elapsedMs > 0 && tokenCount > 0) {
        _lastOutputTokPerSec = tokenCount / (elapsedMs / 1000.0);
        _lastOutputTokens = tokenCount;
        Log.d(
          'Inference',
          'Generation $tokenCount tokens in ${elapsedMs}ms '
              '(${_lastOutputTokPerSec.toStringAsFixed(1)} t/s)',
        );
      }
    } catch (e) {
      yield "Error: ${e.toString()}";
    } finally {
      await _finishGeneration();
    }
  }
}
