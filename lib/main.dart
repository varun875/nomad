import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:home_widget/home_widget.dart';
import 'l10n/app_localizations.dart';
import 'features/onboarding/onboarding_page.dart';
import 'features/chat/chat_screen.dart';
import 'features/chat/chat_history_screen.dart';
import 'features/code/code_screen.dart';
import 'features/creations/creations_screen.dart';

import 'features/creations/creation_app_screen.dart';
import 'features/creations/creation_preview.dart';
import 'features/models/models_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/settings/about_screen.dart';
import 'features/settings/license_screen.dart';
import 'core/widgets/nomad_shell.dart';
import 'core/models/hf_model.dart';
import 'core/services/inference_service.dart';
import 'core/utils/pre_load_cleanup.dart';
import 'core/services/assistant_platform_service.dart';
import 'core/services/search_service.dart';
import 'core/services/memory_service.dart';
import 'core/services/performance_service.dart';
import 'core/services/download_notification_service.dart';
import 'core/theme/nomad_theme.dart';
import 'core/widgets/nomad_animations.dart';
import 'core/widgets/rich_message_renderer.dart';
import 'features/you/you_screen.dart';
import 'features/skills/skills_screen.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'core/services/secure_storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Ensure the caches directory exists on macOS sandbox
  // (getTemporaryDirectory() returns this path but does not create it)
  if (Platform.isMacOS) {
    try {
      final cacheDir = await getApplicationCacheDirectory();
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      print('Cache dir ensured: ${cacheDir.path}');
    } catch (e) {
      print('Warning: could not create cache dir: $e');
    }
  }

  await Hive.initFlutter();
  await Future.wait([
    Hive.openBox('models'),
    Hive.openBox('settings'),
    SecureStorageService.openEncryptedBox('chats'),
  ]);
  final startup = await Future.wait<dynamic>([
    SharedPreferences.getInstance(),
    PerformanceService.instance.init(),
  ]);
  final prefs = startup.first as SharedPreferences;
  final onboarded = prefs.getBool('onboarded') ?? false;
  if (PerformanceService.instance.isLowEnd) {
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = 24 * 1024 * 1024
      ..maximumSize = 50;
  }

  // Web search: TinyFish (per-user Monid key) when configured, else DuckDuckGo.
  await SearchService().loadFromStorage();

  // Release inactive creation webviews before any model load.
  PreLoadCleanup.register(CreationWebviewRegistry.releaseInactive);

  // Low-RAM phones load on demand, avoiding native allocations during startup.
  if (onboarded) {
    var savedModelId = prefs.getString('selectedModelId');
    if (savedModelId != null && savedModelId.isNotEmpty) {
      // OOM crash-loop guard: two consecutive process deaths during a model
      // load mean auto-restore keeps taking the app down. Restore into the
      // smallest downloaded model (the Nano/Lite safe tiers first) instead of
      // crash-looping on the big one.
      final crashes = prefs.getInt(InferenceService.loadCrashGuardKey) ?? 0;
      if (crashes >= 2) {
        final fallbackId = _smallestDownloadedModelId(Hive.box('models'));
        if (fallbackId != null && fallbackId != savedModelId) {
          await prefs.setString('selectedModelId', fallbackId);
          savedModelId = fallbackId;
        }
        await prefs.setInt(InferenceService.loadCrashGuardKey, 0);
      }
      if (!PerformanceService.instance.isLowEnd) {
        unawaited(InferenceService().warmUp(savedModelId));
      }
    }
  }

  // Desktop-aware system UI overlay
  final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  if (!isDesktop) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
    );
  }

  runApp(ProviderScope(child: NomadApp(onboarded: onboarded)));
  // Defer non-critical init until after the first frame so cold start doesn't
  // block on disk/notification I/O or Keystore IPC; all are needed only on later interaction.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(MemoryService().init());
    unawaited(DownloadNotificationService.initialize());
    unawaited(SecureStorageService.openEncryptedBox('creations'));
    unawaited(SecureStorageService.openEncryptedBox('nomad_code_projects'));
  });
}

/// Smallest downloaded model — the OOM crash-loop guard restores into this
/// (the Nano/Lite safe tiers naturally sort first) instead of reloading a
/// model whose allocation keeps killing the process.
String? _smallestDownloadedModelId(Box modelsBox) {
  final downloaded = <HFModel>[];
  for (final key in modelsBox.keys.toList()) {
    try {
      final v = modelsBox.get(key);
      if (v == null) continue;
      final model = HFModel.fromJson(Map<String, dynamic>.from(v as Map));
      if (model.downloaded) downloaded.add(model);
    } catch (_) {}
  }
  if (downloaded.isEmpty) return null;
  downloaded.sort((a, b) => a.sizeMB.compareTo(b.sizeMB));
  return downloaded.first.id;
}

class NomadTransitionPage extends CustomTransitionPage {
  NomadTransitionPage({
    required super.key,
    required super.child,
    this.isForwardLayout = true,
    bool? exitToRight,
  })  : exitToRight = exitToRight ?? isForwardLayout,
        super(
          transitionDuration: NomadDurations.pageTransition,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return NomadPageTransition(
              primaryAnimation: animation,
              secondaryAnimation: secondaryAnimation,
              isForwardLayout: isForwardLayout,
              exitToRight: exitToRight ?? isForwardLayout,
              child: child,
            );
          },
        );

  final bool isForwardLayout;
  final bool exitToRight;
}

Page<dynamic> buildSlidePage({
  required GoRouterState state,
  required Widget child,
  bool? exitToRight,
}) {
  return NomadTransitionPage(
    key: state.pageKey,
    child: child,
    exitToRight: exitToRight,
  );
}

Page<dynamic> buildSlidePageInverse({
  required GoRouterState state,
  required Widget child,
  bool? exitToRight,
}) {
  return NomadTransitionPage(
    key: state.pageKey,
    child: child,
    isForwardLayout: false,
    exitToRight: exitToRight,
  );
}

class NomadApp extends ConsumerStatefulWidget {
  final bool onboarded;
  const NomadApp({super.key, required this.onboarded});

  @override
  ConsumerState<NomadApp> createState() => _NomadAppState();
}

class _NomadAppState extends ConsumerState<NomadApp>
    with WidgetsBindingObserver {
  late final GoRouter _router;
  late final AssistantPlatformService _assistant;
  StreamSubscription<AssistantLaunch>? _assistantLaunches;
  AssistantLaunch? _pendingAssistantLaunch;
  bool _assistantNavigationScheduled = false;
  StreamSubscription<Uri?>? _widgetClicks;

  void _setupWidgetClickHandler() {
    _widgetClicks = HomeWidget.widgetClicked.listen((_) async {
      if (!mounted) return;
      final creationId = await HomeWidget.getWidgetData<String>(
        'creationId',
        defaultValue: '',
      );
      if (mounted && creationId != null && creationId.isNotEmpty) {
        _router.push('/creations/app/$creationId');
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupWidgetClickHandler();
    _router = GoRouter(
      initialLocation: widget.onboarded ? '/home' : '/onboarding',
      routes: [
        GoRoute(
          path: '/onboarding',
          pageBuilder: (context, state) =>
              buildSlidePage(state: state, child: const OnboardingScreen()),
        ),
        ShellRoute(
          pageBuilder: (context, state, child) => buildSlidePageInverse(
            state: state,
            child: NomadShell(child: child),
            exitToRight: true, // Forces the shell to exit right when covered
          ),
          routes: [
            GoRoute(
              path: '/home',
              pageBuilder: (context, state) =>
                  buildSlidePage(state: state, child: const ChatScreen()),
            ),
            GoRoute(
              path: '/assistant',
              pageBuilder: (context, state) => buildSlidePage(
                state: state,
                child: ChatScreen(
                  assistantLaunch: state.extra is AssistantLaunch
                      ? state.extra as AssistantLaunch
                      : const AssistantLaunch(id: 'voice-screen'),
                ),
              ),
            ),
            GoRoute(
              path: '/code',
              pageBuilder: (context, state) => buildSlidePageInverse(
                state: state,
                child: const CodeScreen(),
              ),
            ),
            GoRoute(
              path: '/creations',
              pageBuilder: (context, state) => buildSlidePageInverse(
                state: state,
                child: const CreationsScreen(),
              ),
            ),
            GoRoute(
              path: '/settings/models',
              pageBuilder: (context, state) => buildSlidePageInverse(
                state: state,
                child: const ModelsScreen(),
              ),
            ),
            GoRoute(
              path: '/settings',
              pageBuilder: (context, state) => buildSlidePageInverse(
                state: state,
                child: const SettingsScreen(),
                exitToRight:
                    false, // Forces Settings to slide left when covered so it returns from left-to-right
              ),
              routes: [
                GoRoute(
                  path: 'about',
                  pageBuilder: (context, state) => buildSlidePageInverse(
                    state: state,
                    child: const AboutScreen(),
                  ),
                  routes: [
                    GoRoute(
                      path: 'license/:id',
                      pageBuilder: (context, state) => buildSlidePageInverse(
                        state: state,
                        child: LicenseScreen(id: state.params['id']!),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            GoRoute(
              path: '/you',
              pageBuilder: (context, state) =>
                  buildSlidePageInverse(state: state, child: const YouScreen()),
            ),
            GoRoute(
              path: '/skills',
              pageBuilder: (context, state) => buildSlidePageInverse(
                state: state,
                child: const SkillsScreen(),
              ),
            ),
          ],
        ),
        GoRoute(
          path: '/history',
          pageBuilder: (context, state) => buildSlidePage(
            state: state,
            child: const ChatHistoryScreen(),
            exitToRight: false, // Forces sidebar to slide left when covered
          ),
        ),
        GoRoute(
          path: '/model/:id',
          pageBuilder: (context, state) => buildSlidePage(
            state: state,
            child: ChatScreen(modelId: state.params['id']),
          ),
        ),
        GoRoute(
          path: '/creations/app/:id',
          pageBuilder: (context, state) {
            final id = state.params['id']!;
            return buildSlidePage(
              state: state,
              child: CreationAppScreen(creationId: id),
            );
          },
        ),
      ],
    );
    _router.routerDelegate.addListener(_deliverAssistantLaunch);
    _assistant = ref.read(assistantPlatformProvider);
    _assistantLaunches = _assistant.launches.listen((launch) {
      _pendingAssistantLaunch = launch;
      _deliverAssistantLaunch();
    });
    unawaited(_assistant.start());
  }

  void _deliverAssistantLaunch() {
    if (!mounted ||
        _pendingAssistantLaunch == null ||
        _router.location.startsWith('/onboarding') ||
        _assistantNavigationScheduled) {
      return;
    }
    _assistantNavigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _assistantNavigationScheduled = false;
      if (!mounted || _router.location.startsWith('/onboarding')) return;
      final launch = _pendingAssistantLaunch;
      if (launch == null) return;
      _pendingAssistantLaunch = null;
      if (Uri.parse(_router.location).path != '/assistant') {
        ref.read(chatMessagesProvider.notifier).clear();
      }
      _router.go('/assistant?invocation=${Uri.encodeQueryComponent(launch.id)}',
          extra: launch);
    });
    // An assistant invocation can arrive while the foreground app is idle.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didHaveMemoryPressure() => _releaseIdleMemory();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_assistant.checkPendingLaunch());
    }
    if (PerformanceService.instance.isLowEnd &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      _releaseIdleMemory();
    }
  }

  void _releaseIdleMemory() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    RichMessageRenderer.clearCache();
    unawaited(InferenceService().unloadModel().catchError((Object error) {
      debugPrint('Could not release idle model memory: $error');
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _widgetClicks?.cancel();
    _assistantLaunches?.cancel();
    _router.routerDelegate.removeListener(_deliverAssistantLaunch);
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Nomad',
      debugShowCheckedModeBanner: false,
      theme: NomadTheme.light,
      darkTheme: NomadTheme.dark,
      themeMode: ThemeMode.system,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: _router,
    );
  }
}
