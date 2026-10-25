import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:nomad/core/models/hf_model.dart';
import 'package:nomad/core/providers/download_provider.dart';
import 'package:nomad/core/theme/nomad_theme.dart';
import 'package:nomad/features/creations/creation_app_screen.dart';
import 'package:nomad/features/creations/creation_preview.dart';
import 'package:nomad/features/creations/creations_screen.dart';
import 'package:nomad/l10n/app_localizations.dart';

class _Creations extends StateNotifier<List<Creation>>
    implements CreationsNotifier {
  _Creations(super.initial, this.loaded);
  @override
  final Future<void> loaded;
  void finishLoading(List<Creation> items) => state = items;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads extends StateNotifier<List<HFModel>>
    implements DownloadNotifier {
  _Downloads()
      : super([
          HFModel(
              id: 'test',
              name: 'Test',
              description: '',
              sizeMB: 1,
              speed: 1,
              quality: 1,
              capabilities: [],
              downloaded: true)
        ]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Creation _creation(String id, String type) => Creation(
    id: id,
    title: '$type item',
    html: '<h1>$id</h1>',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    type: type);

ThemeData _theme() => ThemeData(extensions: const [
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
      )
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var windowsRequests = 0;
  setUp(() {
    windowsRequests = 0;
  });
  const windowsVariant = TargetPlatformVariant({TargetPlatform.windows});

  Future<void> pump(
      WidgetTester tester, _Creations store, Widget screen) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ProviderScope(
        overrides: [
          creationsProvider.overrideWith((_) => store),
          downloadProvider.overrideWith((_) => _Downloads()),
          creationWindowsPlatformProvider.overrideWithValue(() async {
            windowsRequests++;
            throw PlatformException(code: 'webview2_runtime_unavailable');
          }),
        ],
        child: MaterialApp(
            theme: _theme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: screen)));
    await tester.pump();
  }

  testWidgets('both category tabs display the persisted singular types',
      (tester) async {
    final store = _Creations(
        [_creation('app', 'playground'), _creation('widget', 'widget')],
        Future.value());
    await pump(tester, store, const CreationsScreen());
    await tester.pumpAndSettle();
    expect(find.text('playground item'), findsOneWidget);
    expect(find.text('widget item'), findsOneWidget);
    await tester.tap(find.text('Playgrounds'));
    await tester.pumpAndSettle();
    expect(find.text('playground item'), findsOneWidget);
    expect(find.text('widget item'), findsNothing);
    await tester.tap(find.text('Widgets'));
    await tester.pumpAndSettle();
    expect(find.text('playground item'), findsNothing);
    expect(find.text('widget item'), findsOneWidget);
    expect(windowsRequests, 0);
  }, variant: windowsVariant);

  testWidgets('a direct viewer waits for storage before deciding not found',
      (tester) async {
    final ready = Completer<void>();
    final store = _Creations([], ready.future);
    await pump(tester, store, const CreationAppScreen(creationId: 'late'));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Creation not found'), findsNothing);
    expect(windowsRequests, 0);
    store.finishLoading([_creation('late', 'playground')]);
    ready.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CreationPreview), findsOneWidget);
    expect(find.text('Creation not found'), findsNothing);
    expect(windowsRequests, 1);
    expect(find.textContaining('WebView2 Runtime'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: windowsVariant);

  testWidgets('missing IDs show not found only after loading completes',
      (tester) async {
    final ready = Completer<void>();
    await pump(tester, _Creations([], ready.future),
        const CreationAppScreen(creationId: 'missing'));
    expect(find.text('Creation not found'), findsNothing);
    ready.complete();
    await tester.pumpAndSettle();
    expect(find.text('Creation not found'), findsOneWidget);
    expect(windowsRequests, 0);
    expect(tester.takeException(), isNull);
  }, variant: windowsVariant);

  testWidgets('storage failures are distinct from missing creations',
      (tester) async {
    final ready = Completer<void>();
    await pump(tester, _Creations([], ready.future),
        const CreationAppScreen(creationId: 'missing'));
    ready.completeError(StateError('unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load creation. Please try again.'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Creation not found'), findsNothing);
    expect(windowsRequests, 0);
    expect(tester.takeException(), isNull);
  }, variant: windowsVariant);

  test(
      'saving immediately after opening cannot be overwritten by initial loading',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('nomad_creations_test_');
    Hive.init(directory.path);
    final box = await Hive.openBox('creations');
    final old = _creation('old', 'playground');
    final created = _creation('new', 'widget');
    await box.put(old.id, old.toJson());
    final store = CreationsNotifier();
    try {
      await store.saveCreation(created);
      await store.loaded;
      expect(store.state.map((item) => item.id), containsAll(['old', 'new']));
      expect(box.get('new'), created.toJson());
    } finally {
      store.dispose();
      await box.close();
      await directory.delete(recursive: true);
    }
  });

  test('all viewers enforce a strict CSP and local-only navigation', () {
    final html = creationHtmlWithCsp(
        '<meta http-equiv="Content-Security-Policy" content="default-src *"><script>1</script>');
    expect(html, startsWith('<meta http-equiv="Content-Security-Policy"'));
    expect(html, contains("connect-src 'none'"));
    expect(html, contains("frame-src 'none'"));
    expect(html, contains("form-action 'none'"));
    expect(isLocalCreationUrl('about:blank'), isTrue);
    expect(isLocalCreationUrl('data:text/html,hello'), isTrue);
    expect(isLocalCreationUrl('https://example.com'), isFalse);
    expect(isLocalCreationUrl('file:///private.txt'), isFalse);
    expect(isLocalCreationUrl('javascript:alert(1)'), isFalse);
  });
}
