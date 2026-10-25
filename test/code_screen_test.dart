import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:llamadart/llamadart.dart';
import 'package:nomad/core/models/hf_model.dart';
import 'package:nomad/core/providers/model_provider.dart';
import 'package:nomad/core/services/inference_service.dart';
import 'package:nomad/core/theme/nomad_theme.dart';
import 'package:nomad/core/widgets/nomad_widgets.dart';
import 'package:nomad/features/code/code_screen.dart';

class _Inference extends Fake implements InferenceService {
  int calls = 0;
  String? prompt;
  String? modelId;
  String? localPath;
  bool cancelled = false;
  late final stream = StreamController<String>(
    onCancel: () {
      cancelled = true;
    },
  );

  @override
  Stream<String> streamChat({
    required String modelId,
    required String prompt,
    String? localPath,
    String? systemPrompt,
    List<Map<String, String>> history = const [],
    int maxTokens = 4096,
    List<String>? imagePaths,
    List<ToolDefinition>? tools,
  }) {
    calls++;
    this.prompt = prompt;
    this.modelId = modelId;
    this.localPath = localPath;
    expect(tools, isNull);
    return stream.stream;
  }
}

// Match Nomad's surfaces without fetching Google Fonts in widget tests.
ThemeData _theme() => ThemeData(
      useMaterial3: true,
      extensions: const [
        NomadColorsExtension(
          textPrimary: NomadColors.lightText,
          textSecondary: NomadColors.lightTextSecondary,
          textTertiary: NomadColors.lightTextTertiary,
          background: NomadColors.lightBackground,
          surface: NomadColors.lightSurface,
          surfaceSecondary: NomadColors.lightSurfaceSecondary,
          border: NomadColors.lightBorder,
          borderStrong: NomadColors.lightBorderStrong,
          overlay: NomadColors.lightOverlay,
          accent: NomadColors.lightAccent,
          accentWarm: NomadColors.lightAccentWarm,
        ),
      ],
    );

HFModel _model({bool downloaded = true}) => HFModel(
      id: 'test-model',
      name: 'Test local model',
      description: '',
      sizeMB: 1,
      speed: 1,
      quality: 1,
      capabilities: const ['text'],
      downloaded: downloaded,
      localPath: downloaded ? '/unused/test-model.gguf' : null,
    );

void main() {
  final encryptionKey = List<int>.generate(32, (i) => i);
  late Directory directory;
  late Box box;
  late _Inference inference;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('nomad_code_test_');
    Hive.init(directory.path);
    box = await Hive.openBox(
      'nomad_code_projects',
      encryptionCipher: HiveAesCipher(encryptionKey),
    );
    inference = _Inference();
  });

  tearDown(() async {
    if (box.isOpen) await box.close();
    directory.deleteSync(recursive: true);
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    HFModel? model,
    Future<Box>? opening,
    double? availableWidth,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedModelProvider.overrideWithValue(model),
          codeInferenceProvider.overrideWithValue(inference),
          if (opening != null) codeDraftBoxProvider.overrideWithValue(opening),
        ],
        child: MaterialApp(
          theme: _theme(),
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: availableWidth,
              child: const CodeScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder field(String name) => find.byKey(ValueKey('code-$name'));
  String textOf(WidgetTester tester, String name) =>
      tester.widget<TextField>(field(name)).controller!.text;

  testWidgets(
      'narrow screen opens the editor and offers Models without inference',
      (tester) async {
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('code-tabs')), findsOneWidget);
    expect(find.byKey(const ValueKey('code-split')), findsNothing);
    expect(field('source'), findsOneWidget);
    expect(textOf(tester, 'filename'), 'scratch.dart');
    expect(find.byTooltip('Copy source'), findsOneWidget);
    expect(find.byTooltip('Export source as a file'), findsOneWidget);
    for (final tooltip in ['Copy source', 'Export source as a file']) {
      final size = tester.getSize(find.byTooltip(tooltip));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    expect(inference.calls, 0);

    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();
    expect(find.text('No downloaded model selected'), findsOneWidget);
    expect(tester.widget<FilledButton>(field('ask')).onPressed, isNull);
    expect(tester.widget<TextButton>(field('models')).onPressed, isNotNull);
    expect(tester.getSize(field('models')).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
    expect(inference.calls, 0);
  });

  testWidgets('wide screen shows editor and assistant side by side',
      (tester) async {
    await pumpScreen(tester, size: const Size(1200, 900));
    expect(find.byKey(const ValueKey('code-tabs')), findsNothing);
    expect(find.byKey(const ValueKey('code-split')), findsOneWidget);
    final editor = find.byKey(const ValueKey('code-editor-panel'));
    final assistant = find.byKey(const ValueKey('code-assistant-panel'));
    expect(tester.getTopLeft(editor).dy, tester.getTopLeft(assistant).dy);
    expect(tester.getTopRight(editor).dx,
        lessThan(tester.getTopLeft(assistant).dx));
    expect(find.text('No downloaded model selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(inference.calls, 0);
  });

  testWidgets('uses available width and scrolls when the keyboard is open',
      (tester) async {
    await pumpScreen(
      tester,
      size: const Size(1200, 700),
      availableWidth: 360,
    );
    expect(find.byKey(const ValueKey('code-tabs')), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding(bottom: 340);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(field('source'), 'final value = 42;');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Assistant'));
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();
    await tester.enterText(field('prompt'), 'Explain the draft');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'explicit save persists one draft and leaves other records intact',
      (tester) async {
    await tester.runAsync(
      () => box.put('existing-project', {'source': 'keep me'}),
    );
    await pumpScreen(tester);
    await tester.enterText(field('filename'), 'example.dart');
    await tester.enterText(field('source'), 'int answer() => 42;\n');
    expect(box.get('scratchpad'), isNull);
    await tester.ensureVisible(field('save'));
    await tester.runAsync(() async {
      await tester.tap(field('save'));
      await box.flush();
    });
    await tester.pumpAndSettle();
    expect(box.get('scratchpad'), {
      'filename': 'example.dart',
      'source': 'int answer() => 42;\n',
    });
    expect(box.get('existing-project'), {'source': 'keep me'});
    expect(find.text('Saved on this device'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    box = (await tester.runAsync(() async {
      await box.close();
      return Hive.openBox(
        'nomad_code_projects',
        encryptionCipher: HiveAesCipher(encryptionKey),
      );
    }))!;
    await pumpScreen(tester);
    expect(textOf(tester, 'filename'), 'example.dart');
    expect(textOf(tester, 'source'), 'int answer() => 42;\n');
    expect(inference.calls, 0);
  });

  testWidgets('a late load never replaces typing in either draft field',
      (tester) async {
    await tester.runAsync(() => box.put('scratchpad', {
          'filename': 'old.dart',
          'source': 'old source',
        }));
    final opening = Completer<Box>();
    await pumpScreen(tester, opening: opening.future);
    await tester.enterText(field('filename'), 'new.dart');
    await tester.enterText(field('source'), 'new source');
    opening.complete(box);
    await tester.pumpAndSettle();
    expect(textOf(tester, 'filename'), 'new.dart');
    expect(textOf(tester, 'source'), 'new source');
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect((box.get('scratchpad') as Map)['source'], 'old source');
  });

  testWidgets('save failures are visible and keep the editable draft',
      (tester) async {
    await pumpScreen(tester, opening: Future.value(box));
    await tester.enterText(field('source'), 'do not lose this');
    await tester.runAsync(() => box.close());
    await tester.ensureVisible(field('save'));
    await tester.tap(field('save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save this draft.'), findsOneWidget);
    expect(textOf(tester, 'source'), 'do not lose this');
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an undownloaded selection cannot start inference',
      (tester) async {
    await pumpScreen(
      tester,
      size: const Size(1200, 900),
      model: _model(downloaded: false),
    );
    await tester.enterText(field('prompt'), 'Review this');
    await tester.pump();
    expect(tester.widget<FilledButton>(field('ask')).onPressed, isNull);
    expect(find.text('No downloaded model selected'), findsOneWidget);
    expect(inference.calls, 0);
  });

  testWidgets('Ask streams only on request and Stop preserves source and reply',
      (tester) async {
    await pumpScreen(
      tester,
      size: const Size(1200, 900),
      model: _model(),
    );
    final source = textOf(tester, 'source');
    expect(inference.calls, 0);
    await tester.enterText(field('prompt'), 'Review this');
    await tester.pump();
    await tester.tap(field('ask'));
    await tester.pump();
    expect(inference.calls, 1);
    expect(inference.modelId, 'test-model');
    expect(inference.localPath, '/unused/test-model.gguf');
    expect(inference.prompt, contains(source));
    expect(inference.prompt, contains('Review this'));
    expect(find.text('Loading model / thinking...'), findsOneWidget);
    inference.stream.add('Consider making the function smaller.');
    await tester.pump();
    expect(tester.widget<SelectableText>(field('response')).data,
        isNot('Consider making the function smaller.'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<SelectableText>(field('response')).data,
        'Consider making the function smaller.');
    expect(textOf(tester, 'source'), source);
    await tester.pump(const Duration(milliseconds: 500));
    inference.stream.add(' Pending suffix.');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(field('stop'));
    });
    await tester.pump();
    expect(inference.cancelled, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Generation stopped.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(textOf(tester, 'source'), source);
    expect(tester.widget<SelectableText>(field('response')).data,
        'Consider making the function smaller. Pending suffix.');
  });

  testWidgets('service error text is surfaced rather than applied to the draft',
      (tester) async {
    await pumpScreen(
      tester,
      size: const Size(1200, 900),
      model: _model(),
    );
    final source = textOf(tester, 'source');
    await tester.enterText(field('prompt'), 'Review this');
    await tester.pump();
    await tester.tap(field('ask'));
    inference.stream.add('Error: Local model file not found.');
    unawaited(inference.stream.close());
    await tester.pumpAndSettle();
    expect(find.text('Local model file not found.'), findsOneWidget);
    expect(find.byKey(const ValueKey('code-stop')), findsNothing);
    expect(textOf(tester, 'source'), source);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short response flushes before the throttle timer fires',
      (tester) async {
    await pumpScreen(tester, size: const Size(1200, 900), model: _model());
    await tester.enterText(field('prompt'), 'Review this');
    await tester.pump();
    await tester.tap(field('ask'));
    inference.stream.add('Short reply');
    unawaited(inference.stream.close());
    await tester.pumpAndSettle();
    expect(
        tester.widget<SelectableText>(field('response')).data, 'Short reply');
    expect(find.byKey(const ValueKey('code-stop')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing the screen cancels an active generation',
      (tester) async {
    await pumpScreen(
      tester,
      size: const Size(1200, 900),
      model: _model(),
    );
    await tester.enterText(field('prompt'), 'Review this');
    await tester.pump();
    await tester.tap(field('ask'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(inference.cancelled, isTrue);
    inference.stream.add('Late token');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('root Code back goes home and Models opens the existing route',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/code',
      routes: [
        GoRoute(path: '/code', builder: (_, __) => const CodeScreen()),
        GoRoute(
          path: '/home',
          builder: (_, __) => const Scaffold(body: Text('Home destination')),
        ),
        GoRoute(
          path: '/settings/models',
          builder: (_, __) => const Scaffold(body: Text('Models destination')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedModelProvider.overrideWithValue(null),
          codeInferenceProvider.overrideWithValue(inference),
        ],
        child: MaterialApp.router(theme: _theme(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(field('models'));
    await tester.pumpAndSettle();
    expect(find.text('Models destination'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NomadBackButton));
    await tester.pumpAndSettle();
    expect(find.text('Home destination'), findsOneWidget);
    router.push('/code');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NomadBackButton));
    await tester.pumpAndSettle();
    expect(find.text('Home destination'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
