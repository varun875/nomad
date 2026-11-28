import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:nomad/core/services/inference_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

LlamaCompletionChunk _chunk() => LlamaCompletionChunk(
      id: 'test',
      object: 'chat.completion.chunk',
      created: 0,
      model: 'test',
      choices: [
        LlamaCompletionChunkChoice(
            index: 0, delta: LlamaCompletionChunkDelta(content: 'hello'))
      ],
    );

class _Engine extends Fake implements LlamaEngine {
  int loads = 0;
  int disposals = 0;
  int projectorLoads = 0;
  int projectorUnloads = 0;
  int generations = 0;
  ModelParams? params;
  Object? loadError;
  Object? projectorError;
  Object? projectorUnloadError;
  Completer<void>? loadGate;
  Completer<void>? projectorUnloadGate;
  final loading = Completer<void>();
  final generating = Completer<void>();
  final releasingProjector = Completer<void>();
  Stream<LlamaCompletionChunk> Function() output = () => Stream.value(_chunk());

  @override
  Future<void> setModel(
    LlamaModel model, {
    ModelParams params = const ModelParams(),
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    loads++;
    this.params = params;
    if (!loading.isCompleted) loading.complete();
    await loadGate?.future;
    if (loadError != null) throw loadError!;
  }

  @override
  Future<void> loadMultimodalProjectorSource(
    ModelSource source, {
    ModelLoadOptions? download,
    ModelLoadOptions? options,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    projectorLoads++;
    if (projectorError != null) throw projectorError!;
  }

  @override
  Future<void> unloadMultimodalProjector() async {
    projectorUnloads++;
    if (!releasingProjector.isCompleted) releasingProjector.complete();
    await projectorUnloadGate?.future;
    if (projectorUnloadError != null) throw projectorUnloadError!;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #create) {
      generations++;
      if (!generating.isCompleted) generating.complete();
      return output();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const mib = 1024 * 1024;

  group('4 GB allocation checks', () {
    test('requires working-memory headroom, not just the weights', () {
      expect(
          InferenceService.allocationError(
            ramGB: 4,
            allocationBytes: 533 * mib,
            memory: (availableBytes: 1045 * mib, lowMemory: false),
          ),
          isNull);
      expect(
          InferenceService.allocationError(
            ramGB: 4,
            allocationBytes: 533 * mib,
            memory: (availableBytes: 1045 * mib - 1, lowMemory: false),
          ),
          contains('Not enough free RAM'));
    });

    test('OS pressure blocks allocations even when byte estimates fit', () {
      expect(
          InferenceService.allocationError(
            ramGB: 4,
            allocationBytes: 229 * mib,
            memory: (availableBytes: 2000 * mib, lowMemory: true),
          ),
          contains('Not enough free RAM'));
    });

    test('oversized models cannot bypass missing memory probes', () {
      expect(
          InferenceService.allocationError(
              ramGB: 4, allocationBytes: 1594 * mib),
          contains('too large'));
      expect(
          InferenceService.allocationError(
              ramGB: 2, allocationBytes: 533 * mib, requiredRAM: 3),
          contains('too large'));
      expect(
          InferenceService.allocationError(
              ramGB: 4, allocationBytes: 533 * mib),
          isNull);
    });

    test('projector checks only charge the additional allocation', () {
      expect(
          InferenceService.allocationError(
            ramGB: 4,
            allocationBytes: 300 * mib,
            projector: true,
            memory: (availableBytes: 556 * mib, lowMemory: false),
          ),
          isNull);
      expect(
          InferenceService.allocationError(
            ramGB: 4,
            allocationBytes: 300 * mib,
            projector: true,
            memory: (availableBytes: 555 * mib, lowMemory: false),
          ),
          contains('image processing'));
    });

    test('the restricted profile is not imposed on higher-RAM devices', () {
      expect(
          InferenceService.allocationError(
              ramGB: 16, allocationBytes: 6000 * mib),
          isNull);
    });
  });

  group('native lifecycle', () {
    late Directory directory;
    late String path;
    late List<_Engine> engines;
    late InferenceService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp('nomad_memory_test_');
      path = '${directory.path}/test.gguf';
      await File(path).writeAsBytes([0]);
      engines = [];
      service = InferenceService.forTesting(engineFactory: () {
        final engine = _Engine();
        engines.add(engine);
        return engine;
      });
    });

    tearDown(() async {
      await service.unloadModel();
      await directory.delete(recursive: true);
    });

    Stream<String> chat({List<String>? images}) => service.streamChat(
          modelId: 'test',
          localPath: path,
          prompt: 'hello',
          imagePaths: images,
        );

    test('low-RAM warmup does not allocate an engine', () async {
      await service.warmUp('test');
      expect(engines, isEmpty);
      expect(service.isLoaded, isFalse);
    });

    test('low free memory rejects before creating a native engine', () async {
      service = InferenceService.forTesting(
        engineFactory: () {
          fail('No native allocation should occur');
        },
        readMemory: () async => (availableBytes: 500 * mib, lowMemory: false),
      );
      expect(await chat().toList(), [contains('Not enough free RAM')]);
      expect(service.isLoaded, isFalse);
      expect(service.isGenerating, isFalse);
    });

    test('unsafe rejection leaves the current safe model intact', () async {
      await service.loadModel(path);
      final unsafe = '${directory.path}/nomad-pro-bonsai25-27b.gguf';
      await File(unsafe).writeAsBytes([0]);
      await expectLater(service.loadModel(unsafe), throwsStateError);
      expect(service.modelPath, path);
      expect(engines.single.disposals, 0);
    });

    test('failed loads are disposed and do not poison the queue', () async {
      final broken = _Engine()..loadError = StateError('load failed');
      final healthy = _Engine();
      var calls = 0;
      service = InferenceService.forTesting(
          engineFactory: () => calls++ == 0 ? broken : healthy);
      final failed = expectLater(service.loadModel(path), throwsStateError);
      final recovered = service.loadModel(path);
      await failed;
      expect(await recovered, path);
      expect(broken.disposals, 1);
      expect(healthy.loads, 1);
      expect(service.isLoaded, isTrue);
    });

    test('a failed replacement cannot retain the previous model path',
        () async {
      final old = _Engine();
      final broken = _Engine()..loadError = StateError('replacement failed');
      final recovered = _Engine();
      final candidates = [old, broken, recovered].iterator;
      service = InferenceService.forTesting(engineFactory: () {
        candidates.moveNext();
        return candidates.current;
      });
      await service.loadModel(path);
      final replacement = '${directory.path}/replacement.gguf';
      await File(replacement).writeAsBytes([0]);
      await expectLater(service.loadModel(replacement), throwsStateError);
      expect(old.disposals, 1);
      expect(broken.disposals, 1);
      expect(service.modelPath, isNull);
      expect(service.isLoaded, isFalse);
      await service.loadModel(path);
      expect(recovered.loads, 1);
      expect(service.modelPath, path);
    });

    test('unload waits for a pending load rather than racing it', () async {
      final engine = _Engine()..loadGate = Completer<void>();
      service = InferenceService.forTesting(engineFactory: () => engine);
      final load = service.loadModel(path);
      await engine.loading.future;
      final unload = service.unloadModel();
      expect(engine.disposals, 0);
      engine.loadGate!.complete();
      await load;
      await unload;
      expect(engine.disposals, 1);
      expect(service.isLoaded, isFalse);
      expect(service.modelPath, isNull);
    });

    test(
        'concurrent requests are rejected and pressure release waits for decode',
        () async {
      await service.loadModel(path);
      final engine = engines.single;
      final tokens = StreamController<LlamaCompletionChunk>();
      engine.output = () => tokens.stream;
      final response = chat().toList();
      await engine.generating.future;
      expect(await chat().toList(), [contains('Another response')]);
      await expectLater(service.loadModel(path), throwsStateError);
      await service.unloadModel();
      expect(engine.disposals, 0);
      tokens.add(_chunk());
      await tokens.close();
      expect(await response, ['hello']);
      expect(engine.generations, 1);
      expect(engine.disposals, 1);
      expect(service.isGenerating, isFalse);
      expect(service.isLoaded, isFalse);
    });

    test(
        'raw completion streams share the same generation guard and idle cleanup',
        () async {
      await service.loadModel(path);
      final engine = engines.single;
      final tokens = StreamController<LlamaCompletionChunk>();
      engine.output = () => tokens.stream;
      final response =
          service.createStream(messages: [], localPath: path)!.toList();
      await engine.generating.future;
      expect(service.createStream(messages: [], localPath: path), isNull);
      expect(await chat().toList(), [contains('Another response')]);
      await service.unloadModel();
      expect(engine.disposals, 0);
      tokens.add(_chunk());
      await tokens.close();
      expect(await response, hasLength(1));
      expect(engine.disposals, 1);
      expect(service.isGenerating, isFalse);
    });

    test('vision is lazy, released after use, and reloadable', () async {
      await File(path.replaceAll('.gguf', '.mmproj')).writeAsBytes([0]);
      await service.loadModel(path);
      final engine = engines.single;
      expect(engine.projectorLoads, 0);
      expect(engine.params!.contextSize, 1536);
      expect(engine.params!.cacheTypeK, KvCacheType.q8_0);
      expect(engine.params!.cacheTypeV, KvCacheType.q8_0);
      expect(engine.params!.gpuLayers, 0);
      expect(await chat(images: ['test.jpg']).toList(), ['hello']);
      expect(engine.projectorLoads, 1);
      expect(engine.projectorUnloads, 1);
      expect(service.isLoaded, isTrue);
      expect(await chat(images: ['test.jpg']).toList(), ['hello']);
      expect(engine.projectorLoads, 2);
      expect(engine.projectorUnloads, 2);
      expect(engine.loads, 1);
    });

    test('vision pressure and multiple images fail before projector allocation',
        () async {
      var free = 2048 * mib;
      final engine = _Engine();
      service = InferenceService.forTesting(
        engineFactory: () => engine,
        readMemory: () async => (availableBytes: free, lowMemory: false),
      );
      await File(path.replaceAll('.gguf', '.mmproj')).writeAsBytes([0]);
      await service.loadModel(path);
      free = 128 * mib;
      expect(await chat(images: ['test.jpg']).toList(),
          [contains('image processing')]);
      expect(await chat(images: ['a.jpg', 'b.jpg']).toList(),
          [contains('one image')]);
      expect(engine.projectorLoads, 0);
      expect(service.isGenerating, isFalse);
    });

    test('canceling a vision response releases its projector', () async {
      await File(path.replaceAll('.gguf', '.mmproj')).writeAsBytes([0]);
      await service.loadModel(path);
      final engine = engines.single;
      final tokens = StreamController<LlamaCompletionChunk>();
      engine.output = () => tokens.stream;
      final response = chat(images: ['test.jpg']).take(1).toList();
      await engine.generating.future;
      tokens.add(_chunk());
      expect(await response, ['hello']);
      expect(engine.projectorUnloads, 1);
      expect(service.isGenerating, isFalse);
      await tokens.close();
    });

    test('failed generation still releases its projector', () async {
      await File(path.replaceAll('.gguf', '.mmproj')).writeAsBytes([0]);
      await service.loadModel(path);
      final engine = engines.single;
      engine.output = () => Stream.error(StateError('prefill failed'));
      expect(await chat(images: ['test.jpg']).toList(),
          [contains('prefill failed')]);
      expect(engine.projectorUnloads, 1);
      expect(service.isGenerating, isFalse);
    });

    test('failed eager projector loading cannot publish a half-ready engine',
        () async {
      final engine = _Engine()..projectorError = StateError('projector failed');
      service =
          InferenceService.forTesting(engineFactory: () => engine, ramGB: 16);
      await File(path.replaceAll('.gguf', '.mmproj')).writeAsBytes([0]);
      await expectLater(service.loadModel(path), throwsStateError);
      expect(engine.disposals, 1);
      expect(service.isLoaded, isFalse);
      expect(service.modelPath, isNull);
    });

    test('pressure arriving during projector cleanup is not lost', () async {
      await File(path.replaceAll('.gguf', '.mmproj')).writeAsBytes([0]);
      await service.loadModel(path);
      final engine = engines.single..projectorUnloadGate = Completer<void>();
      final response = chat(images: ['test.jpg']).toList();
      await engine.releasingProjector.future;
      await service.unloadModel();
      expect(engine.disposals, 0);
      engine.projectorUnloadGate!.complete();
      await response;
      expect(engine.disposals, 1);
      expect(service.isLoaded, isFalse);
    });

    test(
        'failed projector cleanup drops the model instead of retaining stale state',
        () async {
      await File(path.replaceAll('.gguf', '.mmproj')).writeAsBytes([0]);
      await service.loadModel(path);
      final engine = engines.single
        ..projectorUnloadError = StateError('free failed');
      expect(await chat(images: ['test.jpg']).toList(), ['hello']);
      expect(engine.disposals, 1);
      expect(service.isLoaded, isFalse);
      expect(service.isGenerating, isFalse);
    });
  });
}
