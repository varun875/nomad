import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nomad/core/constants/responsive.dart';
import 'package:nomad/core/models/chat_session.dart';
import 'package:nomad/core/models/hf_model.dart';
import 'package:nomad/core/providers/download_provider.dart';
import 'package:nomad/core/providers/model_provider.dart';
import 'package:nomad/core/theme/nomad_theme.dart';
import 'package:nomad/core/widgets/nomad_animations.dart';
import 'package:nomad/core/widgets/nomad_shell.dart';
import 'package:nomad/features/chat/chat_history_screen.dart';
import 'package:nomad/features/chat/chat_screen.dart';
import 'package:nomad/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Downloads extends StateNotifier<List<HFModel>>
    implements DownloadNotifier {
  _Downloads() : super([]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Conversations extends StateNotifier<List<ChatSession>>
    implements ConversationsNotifier {
  _Conversations() : super([]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'),
        (call) async {
      return call.method == 'getVoices' ? [] : 1;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugin.csdcorp.com/speech_to_text'),
        (_) async => false);
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.varun.nomad/storage'), (_) async => null);
  });

  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    required Size size,
    String location = '/home',
    bool realChat = false,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(
      initialLocation: location,
      routes: [
        ShellRoute(
          builder: (context, state, child) => NomadShell(child: child),
          routes: [
            for (final path in [
              '/home',
              '/code',
              '/creations',
              '/you',
              '/skills',
              '/settings/models',
              '/settings'
            ])
              GoRoute(
                  path: path,
                  builder: (_, __) => path == '/home' && realChat
                      ? const ChatScreen()
                      : Scaffold(
                          body: SizedBox.expand(key: ValueKey('page-$path')))),
          ],
        ),
        GoRoute(
            path: '/history', builder: (_, __) => const ChatHistoryScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        conversationsProvider.overrideWith((_) => _Conversations()),
        downloadProvider.overrideWith((_) => _Downloads()),
        selectedModelProvider.overrideWithValue(null),
      ],
      child: MaterialApp.router(
        theme: _theme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    return router;
  }

  Finder nav(String path) => find.byKey(ValueKey('navigation-$path'));

  testWidgets('mobile has a predictable five-destination grid and Code opens',
      (tester) async {
    final router =
        await pumpApp(tester, size: const Size(390, 844), location: '/history');
    expect(find.byKey(const ValueKey('mobile-navigation')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-navigation')), findsNothing);
    expect(find.byIcon(Icons.code_rounded), findsOneWidget);
    expect(tester.getTopLeft(nav('/code')).dy,
        tester.getTopLeft(nav('/creations')).dy);
    expect(tester.getTopLeft(nav('/skills')).dy,
        greaterThan(tester.getTopLeft(nav('/code')).dy));
    for (final path in [
      '/code',
      '/creations',
      '/you',
      '/skills',
      '/settings/models'
    ]) {
      expect(tester.getSize(nav(path)).height, greaterThanOrEqualTo(48));
    }
    await tester.tap(nav('/code'));
    await tester.pumpAndSettle();
    expect(router.location, '/code');
    expect(find.byKey(const ValueKey('page-/code')), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(router.location, '/history');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'desktop rows indicate the active page and stay visible in Models',
      (tester) async {
    final router = await pumpApp(tester, size: const Size(1440, 900));
    expect(find.byKey(const ValueKey('desktop-navigation')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-navigation')), findsNothing);
    expect(
        tester
            .widget<BouncyTap>(find.descendant(
                of: nav('/home'), matching: find.byType(BouncyTap)))
            .selected,
        isTrue);
    expect(tester.getSemantics(nav('/home')).flagsCollection.isSelected,
        Tristate.isTrue,
        reason: tester.getSemantics(nav('/home')).toStringDeep());
    await tester.tap(nav('/code'));
    await tester.pumpAndSettle();
    expect(router.location, '/code');
    expect(tester.getSemantics(nav('/code')).flagsCollection.isSelected,
        Tristate.isTrue);
    expect(tester.getSemantics(nav('/home')).flagsCollection.isSelected,
        Tristate.isFalse);
    await tester.tap(nav('/settings/models'));
    await tester.pumpAndSettle();
    expect(router.location, '/settings/models');
    expect(find.byKey(const ValueKey('desktop-navigation')), findsOneWidget);
    expect(
        tester.getSemantics(nav('/settings/models')).flagsCollection.isSelected,
        Tristate.isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short windows and larger mobile text keep navigation scrollable',
      (tester) async {
    await pumpApp(tester,
        size: const Size(320, 480), location: '/history', textScale: 1.5);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(nav('/settings/models'));
    expect(nav('/settings/models').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Code can use more width than a standard page', (tester) async {
    final router =
        await pumpApp(tester, size: const Size(1800, 1000), location: '/code');
    expect(tester.getSize(find.byKey(const ValueKey('page-/code'))).width,
        greaterThan(ContentWidths.page));
    router.go('/skills');
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('page-/skills'))).width,
        ContentWidths.page);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop chat and composer are centered and capped at 820px',
      (tester) async {
    await pumpApp(tester, size: const Size(1600, 900), realChat: true);
    final column = find.byKey(const ValueKey('chat-column'));
    final composer = find.byKey(const ValueKey('chat-composer'));
    expect(tester.getSize(column).width, ContentWidths.chat);
    expect(tester.getSize(composer).width, ContentWidths.chat);
    final chatRect = tester.getRect(find.byType(ChatScreen));
    expect(tester.getCenter(column).dx, chatRect.center.dx);
    await tester.tap(find.byTooltip('Chat history'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getSize(column).width, ContentWidths.chat);
    expect(tester.getCenter(column).dx, 800);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile composer stays above the keyboard without overflow',
      (tester) async {
    await pumpApp(tester, size: const Size(390, 700), realChat: true);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(
        find.byType(TextField), 'A multiline\nmessage\nfor Nomad');
    await tester.pump(const Duration(milliseconds: 500));
    final composer = find.byKey(const ValueKey('chat-composer'));
    expect(tester.getBottomRight(composer).dy, lessThanOrEqualTo(380));
    expect(tester.getSize(composer).width, 350);
    expect(tester.takeException(), isNull);
  });
}
