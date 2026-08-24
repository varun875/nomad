import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_info_service.dart';
import 'model_service.dart';
import 'performance_service.dart';
import '../utils/logger.dart';

class InferenceService {
  static const generationThreadsPreference = 'inferenceGenerationThreads';
  static final InferenceService _instance = InferenceService._internal();
  factory InferenceService() => _instance;
  InferenceService._internal() {
    LlamaEngine.configureLogging(level: LlamaLogLevel.none);
  }

  LlamaEngine? _engine;
  String? _loadedModelPath;
  String? _availableMmProjPath;
  String? _loadedMmProjPath;

  double _lastPromptTokPerSec = 0;
  double _lastOutputTokPerSec = 0;
  int _lastPromptTokens = 0;
  int _lastOutputTokens = 0;

  double get lastPromptTokPerSec => _lastPromptTokPerSec;
  double get lastOutputTokPerSec => _lastOutputTokPerSec;
  int get lastPromptTokens => _lastPromptTokens;
  int get lastOutputTokens => _lastOutputTokens;

  bool get isLoaded => _engine != null && _loadedModelPath != null;

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
    final threads =
        resolveOptimalThreads(constrained: constrained, processors: processors, performanceCores: performanceCores);
    Log.d(
      'Inference',
      'Threads: $performanceCores perf-cores/$processors cores -> $threads threads',
    );
    return threads;
  }

  /// Serializes model loads so warm-up raced with a first message never loads
  /// the same engine twice (which spiked memory and could crash natively).
  Future<String> _activeLoad = Future<String>.value('');

  Future<String> loadModel(String localPath) async {
    final result = _activeLoad.then((_) => _loadModelInternal(localPath));
    // Chain the current load so concurrent callers wait for it instead of
    // double-loading. On failure reset the queue so the next load can
    // proceed, but propagate the error to this caller (don't mask as success).
    _activeLoad = result.then((v) => v, onError: (Object e, StackTrace s) {
      _activeLoad = Future<String>.value('');
      // Re-throw to keep error for chained catchError, but _activeLoad is reset.
      throw e;
    });
    return result;
  }

  Future<String> _loadModelInternal(String localPath) async {
    final stat = await File(localPath).stat();
    if (stat.type == FileSystemEntityType.notFound) {
      throw Exception('Model file not found: $localPath');
    }

    if (_loadedModelPath == localPath && _engine != null) {
      return localPath;
    }

    if (_engine != null) {
      await _engine!.dispose();
      _engine = null;
    }

    final fileSizeMB = stat.size ~/ (1024 * 1024);
    final mmProjPath = localPath.replaceAll('.gguf', '.mmproj');
    final hasVision = await File(mmProjPath).exists();

    // Dynamically scale context size based on platform and available RAM to optimize memory on mobile
    int ctx = 2048;
    if (Platform.isAndroid || Platform.isIOS) {
      final ram = await ModelService.getDeviceRAM();
      if (ram <= 4) {
        ctx = 2048; // Safe fallback to prevent OOM crashes on low-end devices
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

    final gpuLayers = _detectOptimalGpuLayers();

    _engine = LlamaEngine(LlamaBackend());

    // Configure model with optimized parameters:
    // - On mobile: enable Flash Attention and Q8_0 KV Cache quantization to reduce RAM by 50%
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final constrained = isMobile &&
        (PerformanceService.instance.isConstrained ||
            PerformanceService.instance.deviceRamGb <= 8);
    final lowEnd = isMobile && PerformanceService.instance.isLowEnd;
    final threadOverride = await _generationThreadOverride();
    final generationThreads =
        threadOverride ?? _optimalGenerationThreads(constrained);
    final batchThreads = _optimalBatchThreads();
    // 32-bit ARMv7 devices typically carry a ~256KB-1MB L2 per core; keep the
    // native batch small enough to stay resident instead of thrashing it.
    final armv7 = Platform.isAndroid && _detectArmv7();
    // Large models on constrained (6-8GB) phones use the smaller 128/64
    // profile you requested - saves ~200MB peak during prefill vs 256/128.
    final isLargeConstrained = constrained && fileSizeMB >= 1000;
    final batchSize = armv7
        ? 64
        : (lowEnd || isLargeConstrained ? 128 : (constrained ? 256 : 1024));
    final microBatchSize = armv7
        ? 32
        : (lowEnd || isLargeConstrained ? 64 : (constrained ? 128 : 512));
    await _engine!.loadModel(
      localPath,
      modelParams: ModelParams(
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
        flashAttention: isMobile ? FlashAttention.enabled : FlashAttention.auto,
        cacheTypeK: isMobile ? KvCacheType.q8_0 : KvCacheType.f16,
        cacheTypeV: isMobile ? KvCacheType.q8_0 : KvCacheType.f16,
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
    _availableMmProjPath = null;
    _loadedMmProjPath = null;
    if (hasVision) {
      if (isMobile && constrained) {
        _availableMmProjPath = mmProjPath;
      } else {
        await _engine!.loadMultimodalProjector(mmProjPath);
        _loadedMmProjPath = mmProjPath;
      }
    }

    _loadedModelPath = localPath;
    _contextSize = ctx;
    return localPath;
  }

  /// Pre-warm the engine by loading the model in the background.
  /// Call this on app start so the first message is near-instant.
  Future<void> warmUp(String modelId) async {
    // Loads the last-used model in the background so it's ready.
    try {
      final directory = await getApplicationDocumentsDirectory();
      final modelPath =
          '${directory.path}/models/${modelId.replaceAll('/', '_')}.gguf';
      if (await File(modelPath).exists()) {
        await loadModel(modelPath);
      }
    } catch (_) {
      // Silently ignore — inference will lazy-load if warmup fails
    }
  }

  Future<void> unloadModel() async {
    if (_engine != null) {
      await _engine!.dispose();
      _engine = null;
    }
    _loadedModelPath = null;
    _availableMmProjPath = null;
    _loadedMmProjPath = null;
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
      if (_loadedModelPath != localPath || _engine == null) return null;

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

      return _engine!.create(messages, params: params, tools: tools);
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
    List<ToolDefinition>? tools,
  }) async* {
    if (localPath == null || !(await File(localPath).exists())) {
      yield "Error: Local model file not found at $localPath.";
      return;
    }

    try {
      if (_loadedModelPath != localPath) {
        await loadModel(localPath);
      }

      if (_engine == null) {
        yield "Error: Failed to load model engine.";
        return;
      }

      // Load the vision encoder lazily on low-RAM phones: the mmproj was
      // deferred at model load time and is only needed for image messages.
      if (imagePaths != null && imagePaths.isNotEmpty) {
        final mmProjPath = localPath.replaceAll('.gguf', '.mmproj');
        final visionAvailable = _availableMmProjPath != null ||
            _loadedMmProjPath != null ||
            await File(mmProjPath).exists();
        if (!visionAvailable) {
          yield "Error: The current model does not support image input. Switch to a vision-capable model or remove the attached image.";
          return;
        }
        if (_availableMmProjPath != null && _loadedMmProjPath == null) {
          await _engine!.loadMultimodalProjector(_availableMmProjPath!);
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

      if (imagePaths != null && imagePaths.isNotEmpty) {
        final parts = <LlamaContentPart>[
          LlamaTextContent(prompt),
          for (final path in imagePaths) LlamaImageContent(path: path),
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

      final lowEnd = PerformanceService.instance.isLowEnd;
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
      final tokenCount = outputChars == 0
          ? 0
          : (outputChars / 3.5).round().clamp(1, 1 << 31);
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
    }
  }
}
