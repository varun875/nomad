import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:nomad/core/services/memory_service.dart';
import 'package:nomad/core/theme/nomad_theme.dart';
import 'package:nomad/core/widgets/nomad_animations.dart';
import 'package:nomad/core/widgets/nomad_widgets.dart';
import 'package:nomad/features/you/you_screen.dart';

class _InitializingMemories extends Fake implements MemoryService {
  _InitializingMemories(this.memories, {this.opening});

  final List<Memory> memories;
  final Future<void>? opening;
  bool fail = false;
  int initCalls = 0;
  int reads = 0;

  @override
  Future<void> init() async {
    initCalls++;
    if (opening != null) await opening;
    if (fail) throw StateError('Storage is unavailable');
  }

  @override
  List<Memory> getAllMemories() {
    reads++;
    return memories;
  }
}

// Use Nomad's colors without runtime Google Fonts requests.
ThemeData _theme() => ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(primary: NomadColors.lightText),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final encryptionKey = List<int>.generate(32, (index) => index);
  late Directory directory;
  late Box box;

  setUp(() async {
    // Never initialize Hive with an application directory or use the keychain.
    directory = await Directory.systemTemp.createTemp('nomad_you_test_');
    Hive.init(directory.path);
    FlutterSecureStorage.setMockInitialValues({
      'nomad_hive_key': base64Encode(encryptionKey),
    });
    box = await Hive.openBox(
      'memories',
      encryptionCipher: HiveAesCipher(encryptionKey),
    );
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<List<Memory>> seed(WidgetTester tester, int count) async {
    final memories = List.generate(
      count,
      (index) => Memory(
        id: 'saved-$index',
        content: 'Remembered item ${index + 1}',
        category: ['fact', 'preference', 'biography', 'general'][index % 4],
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await tester.runAsync(() => box.putAll({
          for (final memory in memories) memory.id: memory.toJson(),
        }));
    return memories;
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double? availableWidth,
    double textScale = 1,
    bool lowEnd = false,
    bool reducedMotion = false,
    bool screenReader = false,
    MemoryService? service,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        youLowEndProvider.overrideWithValue(lowEnd),
        if (service != null)
          youMemoryServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
        theme: _theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reducedMotion,
            accessibleNavigation: screenReader,
          ),
          child: child!,
        ),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: availableWidth, child: const YouScreen()),
        ),
      ),
    ));
  }

  Finder memoryTile(Memory memory) =>
      find.byKey(ValueKey('memory-${memory.id}'));
  Finder memoryList() => find.byKey(const PageStorageKey('memory-list'));
  Finder listScrollable() => find.descendant(
        of: memoryList(),
        matching: find.byType(Scrollable),
      );

  void expectTarget(WidgetTester tester, Finder finder) {
    final size = tester.getSize(finder);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(finder.hitTestable(), findsOneWidget);
  }

  Future<void> reveal(WidgetTester tester, Memory memory) async {
    tester.state<ScrollableState>(listScrollable()).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(
      memoryTile(memory),
      180,
      scrollable: listScrollable(),
    );
    await tester.pumpAndSettle();
    expectTarget(tester, memoryTile(memory));
  }

  testWidgets(
      'waits for initialization instead of displaying an empty snapshot',
      (tester) async {
    final memories = await seed(tester, 4);
    final opening = Completer<void>();
    final service = _InitializingMemories(memories, opening: opening.future);
    await pumpScreen(tester, service: service);
    expect(service.initCalls, 1);
    expect(service.reads, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Nothing remembered yet'), findsNothing);
    final add = find.ancestor(
      of: find.byTooltip('Add memory'),
      matching: find.byType(BouncyTap),
    );
    expect(tester.widget<BouncyTap>(add).onTap, isNull);
    await tester.tap(find.byTooltip('Add memory'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);

    opening.complete();
    await tester.pumpAndSettle();
    expect(service.reads, 1);
    expect(find.text('4 memories'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await reveal(tester, memories.last);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reopens encrypted storage and exposes all four memories at 390px',
      (tester) async {
    final memories = await seed(tester, 4);
    await tester.runAsync(() => box.close());
    expect(Hive.isBoxOpen('memories'), isFalse);
    await tester.runAsync(() async {
      await pumpScreen(tester);
      await MemoryService().init();
    });
    await tester.pumpAndSettle();
    expect(Hive.isBoxOpen('memories'), isTrue);
    expect(memoryList(), findsOneWidget);
    expect(find.text('Nothing remembered yet'), findsNothing);
    expectTarget(tester, find.byTooltip('Add memory'));
    expectTarget(tester, find.byType(NomadBackButton));

    for (final memory in memories) {
      await reveal(tester, memory);
      final data = tester.getSemantics(memoryTile(memory)).getSemanticsData();
      expect(data.label, 'View ${memory.category} memory: ${memory.content}');
      expect(data.flagsCollection.isButton, isTrue);
      final rect = tester.getRect(memoryTile(memory));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(390));
      await tester.tap(memoryTile(memory));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
            of: find.byType(BottomSheet), matching: find.text(memory.content)),
        findsOneWidget,
      );
      expectTarget(tester, find.byTooltip('Delete memory'));
      expectTarget(tester, find.byTooltip('Close memory'));
      await tester.tap(find.byTooltip('Close memory'));
      await tester.pumpAndSettle();
    }
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a small viewport with large text can scroll to every stored memory',
      (tester) async {
    final memories = await seed(tester, 40);
    await pumpScreen(tester, size: const Size(320, 480), textScale: 1.5);
    await tester.pumpAndSettle();
    expect(memoryList(), findsOneWidget);
    expect(memoryTile(memories.last), findsNothing);
    expect(find.byTooltip('Show memory orbit'), findsNothing);
    for (final memory in memories) {
      await reveal(tester, memory);
      expect(tester.getRect(memoryTile(memory)).right, lessThanOrEqualTo(320));
    }
    expectTarget(tester, find.byTooltip('Add memory'));
    await tester.tap(memoryTile(memories.last));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expectTarget(tester, find.byTooltip('Delete memory'));
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['low-end', 'reduced motion', 'screen reader']) {
    testWidgets('$mode uses a non-animating list even in a wide viewport',
        (tester) async {
      final memories = await seed(tester, 40);
      await pumpScreen(
        tester,
        size: const Size(1200, 1000),
        lowEnd: mode == 'low-end',
        reducedMotion: mode == 'reduced motion',
        screenReader: mode == 'screen reader',
      );
      await tester.pumpAndSettle();
      expect(memoryList(), findsOneWidget);
      expect(find.byIcon(Icons.person_rounded), findsNothing);
      expect(find.byTooltip('Show memory orbit'), findsNothing);
      await tester.scrollUntilVisible(
        memoryTile(memories.last),
        500,
        scrollable: listScrollable(),
      );
      await tester.pumpAndSettle();
      expectTarget(tester, memoryTile(memories.last));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop orbit stays inside its controls and switches to a list',
      (tester) async {
    final memories = await seed(tester, 4);
    await pumpScreen(tester, size: const Size(1200, 900));
    await tester.pump();
    expect(memoryList(), findsNothing);
    expectTarget(tester, find.byTooltip('Show memory list'));
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(seconds: 3));
      for (final memory in memories) {
        expectTarget(tester, memoryTile(memory));
        final rect = tester.getRect(memoryTile(memory));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(1200));
        expect(rect.top,
            greaterThan(tester.getBottomRight(find.byType(NomadTitle)).dy));
        expect(rect.bottom,
            lessThan(tester.getTopLeft(find.byTooltip('Add memory')).dy));
      }
    }
    await tester.tap(memoryTile(memories.first));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Delete memory'));
      await box.flush();
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(box.containsKey(memories.first.id), isFalse);
    expect(memoryTile(memories.first), findsNothing);

    await tester.tap(find.byTooltip('Show memory list'));
    await tester.pumpAndSettle();
    expect(memoryList(), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await reveal(tester, memories.last);
    await tester.ensureVisible(find.byTooltip('Show memory orbit'));
    await tester.tap(find.byTooltip('Show memory orbit'));
    await tester.pump();
    expect(memoryList(), findsNothing);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(memoryList(), findsOneWidget);
    await reveal(tester, memories.last);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'desktop list exposes crowded orbits and respects available width',
      (tester) async {
    final memories = await seed(tester, 40);
    await pumpScreen(tester, size: const Size(1200, 1000));
    await tester.pump();
    await tester.tap(find.byTooltip('Show memory list'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      memoryTile(memories.last),
      500,
      scrollable: listScrollable(),
    );
    await tester.pumpAndSettle();
    expectTarget(tester, memoryTile(memories.last));

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpScreen(
      tester,
      size: const Size(1200, 1000),
      availableWidth: 390,
    );
    await tester.pumpAndSettle();
    expect(memoryList(), findsOneWidget);
    expect(find.byTooltip('Show memory list'), findsNothing);
    expect(tester.getSize(memoryList()).width, 390);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'add, view long content, and delete preserve other stored memories',
      (tester) async {
    final existing = (await seed(tester, 1)).single;
    await pumpScreen(tester, size: const Size(390, 700), textScale: 1.3);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add memory'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pumpAndSettle();
    final save = find.widgetWithText(TextButton, 'Save');
    expectTarget(tester, save);
    expectTarget(tester, find.widgetWithText(TextButton, 'Cancel'));
    expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.labelText,
        'Memory');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Enter a memory to save.'), findsOneWidget);
    expect(box.length, 1);

    final content =
        '${List.filled(60, 'A remembered detail with enough text to wrap.').join('\n')}\nEnd of this memory.';
    await tester.enterText(find.byType(TextField), '  $content  ');
    await tester.runAsync(() async {
      await tester.tap(save);
      await box.flush();
    });
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final saved = MemoryService()
        .getAllMemories()
        .singleWhere((memory) => memory.id != existing.id);
    expect(saved.content, content);
    expect(box.get(existing.id), existing.toJson());
    await reveal(tester, saved);
    await tester.tap(memoryTile(saved));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(find.descendant(of: sheet, matching: find.text(content)),
        findsOneWidget);
    final detailScroll = find.descendant(
      of: sheet,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(detailScroll).position;
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.drag(detailScroll, const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expectTarget(tester, find.byTooltip('Delete memory'));
    expectTarget(tester, find.byTooltip('Close memory'));
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Delete memory'));
      await box.flush();
    });
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(box.containsKey(saved.id), isFalse);
    expect(box.get(existing.id), existing.toJson());
    expect(memoryTile(saved), findsNothing);
    expect(find.text('1 memory'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'initialization failures offer a retry rather than an empty state',
      (tester) async {
    final memories = await seed(tester, 1);
    final service = _InitializingMemories(memories)..fail = true;
    await pumpScreen(tester, service: service);
    await tester.pumpAndSettle();
    expect(find.text('Could not load memories. Please try again.'),
        findsOneWidget);
    expect(find.text('Nothing remembered yet'), findsNothing);
    expect(service.reads, 0);
    final retry = find.ancestor(
      of: find.text('Retry loading memories'),
      matching: find.bySubtype<TextButton>(),
    );
    expectTarget(tester, retry);
    service.fail = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(service.initCalls, 2);
    expect(memoryTile(memories.single), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving during startup does not update disposed state',
      (tester) async {
    final opening = Completer<void>();
    final service = _InitializingMemories([], opening: opening.future);
    await pumpScreen(tester, service: service);
    await tester.pumpWidget(const SizedBox.shrink());
    opening.complete();
    await tester.pump();
    expect(service.reads, 0);
    expect(tester.takeException(), isNull);
  });
}
