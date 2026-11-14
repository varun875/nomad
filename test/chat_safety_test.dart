import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:llamadart/llamadart.dart' hide ChatSession;
import 'package:nomad/core/models/chat_session.dart';
import 'package:nomad/core/models/hf_model.dart';
import 'package:nomad/core/providers/download_provider.dart';
import 'package:nomad/core/providers/model_provider.dart';
import 'package:nomad/core/providers/skill_provider.dart';
import 'package:nomad/core/services/inference_service.dart';
import 'package:nomad/core/services/assistant_platform_service.dart';
import 'package:nomad/core/services/voice_session_controller.dart';
import 'package:nomad/core/theme/nomad_theme.dart';
import 'package:nomad/core/widgets/nomad_shell.dart';
import 'package:nomad/features/chat/chat_history_screen.dart';
import 'package:nomad/features/chat/chat_screen.dart';
import 'package:nomad/l10n/app_localizations.dart';
import 'package:nomad/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/voice_fakes.dart';

final _model = HFModel(
    id: 'test',
    name: 'Test model',
    description: '',
    sizeMB: 1,
    speed: 1,
    quality: 1,
    capabilities: ['text'],
    downloaded: true,
    localPath: '/test.gguf');

class _Inference extends Fake implements InferenceService {
  Stream<String> Function() output = () => Stream.value('A complete response.');
  final histories = <List<Map<String, String>>>[];
  bool busy = false;
  @override
  bool get isLoaded => true;
  @override
  bool get isGenerating => busy;
  @override
  String get modelPath => _model.localPath!;
  @override
  int get contextSize => 4096;
  @override
  double get lastOutputTokPerSec => 0;
  @override
  int get lastOutputTokens => 0;
  @override
  Stream<String> streamChat(
      {required String modelId,
      required String prompt,
      String? localPath,
      String? systemPrompt,
      List<Map<String, String>> history = const [],
      int maxTokens = 4096,
      List<String>? imagePaths,
      List<String>? audioPaths,
      ThinkingBudget? thinkingBudget,
      List<ToolDefinition>? tools}) {
    histories.add(history);
    return output();
  }
}

class _Downloads extends StateNotifier<List<HFModel>>
    implements DownloadNotifier {
  _Downloads() : super([_model]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Conversations extends StateNotifier<List<ChatSession>>
    implements ConversationsNotifier {
  _Conversations(super.initial);
  final writes = <ChatSession>[];
  Completer<void>? saveGate;
  @override
  Future<void> updateConversation(ChatSession conversation) async {
    writes.add(conversation);
    state = [
      conversation,
      ...state.where((item) => item.id != conversation.id)
    ];
    await saveGate?.future;
  }

  @override
  Future<void> deleteConversation(String id) async {
    state = state.where((item) => item.id != id).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Skills extends StateNotifier<List<Skill>> implements SkillNotifier {
  _Skills() : super([]);
  @override
  List<ToolDefinition> getActiveTools() => [];
  @override
  String getActiveSkillInstructions() => '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

ChatSession _savedB() => ChatSession(
        id: 'B',
        title: 'Saved B',
        updatedAt: DateTime.utc(2026),
        projectId: 'keep-project',
        messages: [
          ChatMessage(
              text: 'Earlier question B',
              fromUser: true,
              time: DateTime.utc(2026)),
          ChatMessage(
              text: 'Earlier response B.',
              fromUser: false,
              time: DateTime.utc(2026)),
        ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'),
        (call) async => call.method == 'getVoices' ? [] : 1);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugin.csdcorp.com/speech_to_text'),
        (_) async => false);
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.varun.nomad/storage'), (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('home_widget/updates'), (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async => null);
  });

  test(
      'new and opened conversations change identity atomically with their messages',
      () {
    final chat = ChatMessagesNotifier();
    addTearDown(chat.dispose);
    final a = chat.ensureConversationId();
    chat.openConversation(_savedB());
    expect(chat.conversationId, 'B');
    expect(chat.state.first.text, 'Earlier question B');
    expect(chat.revision, 1);
    chat.clear();
    expect(chat.state, isEmpty);
    expect(chat.conversationId, isNull);
    expect(chat.ensureConversationId(), isNot(a));
    expect(chat.revision, 2);
  });

  Future<ProviderContainer> pumpApp(
      WidgetTester tester, _Conversations store, _Inference inference,
      {VoiceFixture? voice,
      AssistantPlatformService? platform,
      bool modelAvailable = true,
      bool rootApp = false,
      bool onboarded = true,
      Size size = const Size(1400, 900)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(initialLocation: '/home', routes: [
      ShellRoute(builder: (_, __, child) => NomadShell(child: child), routes: [
        GoRoute(path: '/home', builder: (_, __) => const ChatScreen()),
        GoRoute(
            path: '/settings',
            builder: (_, __) => const Scaffold(body: Text('Settings test'))),
        GoRoute(
            path: '/settings/models',
            builder: (_, __) => const Scaffold(body: Text('Models test'))),
      ]),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
        overrides: [
          conversationsProvider.overrideWith((_) => store),
          downloadProvider.overrideWith((_) => _Downloads()),
          skillProvider.overrideWith((_) => _Skills()),
          selectedModelProvider
              .overrideWithValue(modelAvailable ? _model : null),
          chatInferenceProvider.overrideWithValue(inference),
          if (voice != null) ...[
            voiceSessionProvider.overrideWithValue(voice.session),
            assistantPlatformProvider.overrideWithValue(voice.platform),
          ] else if (platform != null)
            assistantPlatformProvider.overrideWithValue(platform),
        ],
        child: rootApp
            ? NomadApp(onboarded: onboarded)
            : MaterialApp.router(
                theme: _theme(),
                routerConfig: router,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    return ProviderScope.containerOf(
        tester.element(find.byType(rootApp ? NomadApp : ChatScreen)));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0;
        i < 40 && find.byTooltip('Stop generating').evaluate().isNotEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byTooltip('Stop generating'), findsNothing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
  }

  Future<void> send(WidgetTester tester, String message) async {
    await tester.enterText(find.byType(TextField), message);
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await finish(tester);
  }

  testWidgets(
      'replying in saved B cannot overwrite A or reset the saved title/project',
      (tester) async {
    final store = _Conversations([_savedB()]);
    final inference = _Inference();
    await pumpApp(tester, store, inference);
    await send(tester, 'Question A');
    final savedA = store.state.first;
    await tester.tap(find.text('Saved B'));
    await tester.pump();
    await send(tester, 'Continue B');
    expect(store.state.first.id, 'B');
    expect(store.state.first.title, 'Saved B');
    expect(store.state.first.projectId, 'keep-project');
    expect(
        store.state.first.messages.map((m) => m.text), contains('Continue B'));
    expect(store.state.firstWhere((c) => c.id == savedA.id).messages,
        savedA.messages);
    expect(inference.histories.last.map((m) => m['content']),
        contains('Earlier question B'));
  });

  testWidgets('sidebar New chat gets a fresh ID without overwriting history',
      (tester) async {
    final store = _Conversations([]);
    await pumpApp(tester, store, _Inference());
    await send(tester, 'First conversation');
    final first = store.state.single;
    await tester.tap(find.descendant(
        of: find.byType(ChatHistoryScreen),
        matching: find.byTooltip('New chat')));
    await tester.pump();
    await send(tester, 'Second conversation');
    expect(store.state, hasLength(2));
    expect(store.state.first.id, isNot(first.id));
    expect(store.state.last.messages, first.messages);
  });

  testWidgets(
      'switching while streaming cancels A and cannot append late tokens to B',
      (tester) async {
    var canceled = false;
    final tokens = StreamController<String>(onCancel: () {
      canceled = true;
    });
    final inference = _Inference()..output = () => tokens.stream;
    final store = _Conversations([_savedB()]);
    final container = await pumpApp(tester, store, inference);
    await tester.enterText(find.byType(TextField), 'Question A');
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    tokens.add('Partial A');
    await tester.pump();
    await tester.tap(find.text('Saved B'));
    await finish(tester);
    tokens.add('Late A');
    await tester.pump();
    expect(canceled, isTrue);
    expect(container.read(chatMessagesProvider).map((m) => m.text),
        ['Earlier question B', 'Earlier response B.']);
    expect(store.state.firstWhere((c) => c.id != 'B').messages.single.text,
        'Question A');
    expect(store.state.firstWhere((c) => c.id == 'B').messages, hasLength(2));
    unawaited(tokens.close());
    await tester.pump();
  });

  testWidgets('switching during the initial save never starts stale generation',
      (tester) async {
    final gate = Completer<void>();
    final store = _Conversations([_savedB()])..saveGate = gate;
    final inference = _Inference();
    final container = await pumpApp(tester, store, inference);
    await tester.enterText(find.byType(TextField), 'Question A');
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    await tester.tap(find.text('Saved B'));
    await tester.pump();
    gate.complete();
    await finish(tester);
    expect(inference.histories, isEmpty);
    expect(container.read(activeConversationIdProvider), 'B');
    expect(
        container.read(chatMessagesProvider).first.text, 'Earlier question B');
  });

  testWidgets(
      'empty responses clear busy state and allow a retry in the same chat',
      (tester) async {
    final inference = _Inference()..output = () => const Stream.empty();
    final store = _Conversations([]);
    await pumpApp(tester, store, inference);
    await send(tester, 'Hello');
    expect(store.state.single.messages.last.text, contains('returned no text'));
    final id = store.state.single.id;
    inference.output = () => Stream.value('Recovered.');
    await tester.tap(find.text('Retry'));
    await finish(tester);
    expect(store.state.single.id, id);
    expect(store.state.single.messages.where((m) => m.fromUser), hasLength(1));
    expect(store.state.single.messages.last.text, 'Recovered.');
  });

  testWidgets('unexpected generation errors also release busy state',
      (tester) async {
    final inference = _Inference()
      ..output = () => Stream.error(StateError('test failure'));
    final store = _Conversations([]);
    await pumpApp(tester, store, inference);
    await send(tester, 'Hello');
    expect(store.state.single.messages.single.text, 'Hello');
    inference.output = () => Stream.value('Recovered.');
    await send(tester, 'Again');
    expect(store.state.single.messages.last.text, 'Recovered.');
  });

  Future<void> cleanVoice(WidgetTester tester, VoiceFixture voice) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final disposed = voice.dispose();
    await tester.pump();
    await disposed;
    await tester.pump();
  }

  Future<void> voiceFrames(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  }

  testWidgets(
      'voice asks, saves, speaks, and automatically listens for the next turn',
      (tester) async {
    final voice = VoiceFixture();
    final store = _Conversations([]);
    await pumpApp(tester, store, _Inference(),
        voice: voice, size: const Size(390, 844));
    try {
      expect(voice.input.initializations, 0);
      await tester.tap(find.byTooltip('Nomad Voice'));
      await voiceFrames(tester);
      expect(find.text('Listening'), findsOneWidget);
      voice.input.current.result('Explain gravity simply', false);
      await tester.pump();
      expect(find.byKey(const ValueKey('voice-transcript')), findsOneWidget);
      voice.input.current.result('Explain gravity simply', true);
      await voiceFrames(tester);
      expect(store.state.single.messages.map((m) => m.text),
          ['Explain gravity simply', 'A complete response.']);
      expect(voice.output.spoken, ['A complete response.']);
      expect(find.text('Speaking'), findsOneWidget);
      expect(voice.input.recording, isFalse);
      voice.output.finishCurrent();
      await voiceFrames(tester);
      expect(find.text('Listening'), findsOneWidget);
      expect(voice.input.sessions, hasLength(2));
    } finally {
      await cleanVoice(tester, voice);
    }
  });

  testWidgets(
      'voice exit restores a typed draft and ignores late recognizer callbacks',
      (tester) async {
    final voice = VoiceFixture();
    await pumpApp(tester, _Conversations([]), _Inference(), voice: voice);
    try {
      await tester.enterText(find.byType(TextField), 'Keep my draft');
      await tester.pump();
      await tester.tap(find.byTooltip('Nomad Voice'));
      await voiceFrames(tester);
      final old = voice.input.current;
      await tester.tap(find.byTooltip('End voice'));
      await voiceFrames(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Keep my draft');
      old.result('late request', true);
      old.level(20);
      await tester.pump();
      expect(voice.output.spoken, isEmpty);
      expect(voice.session.isActive, isFalse);
    } finally {
      await cleanVoice(tester, voice);
    }
  });

  testWidgets(
      'phone actions work without a model and general questions offer model setup',
      (tester) async {
    final voice = VoiceFixture()..output.autoComplete = true;
    final store = _Conversations([]);
    await pumpApp(tester, store, _Inference(),
        voice: voice, modelAvailable: false, size: const Size(390, 844));
    try {
      await tester.tap(find.byTooltip('Nomad Voice'));
      await voiceFrames(tester);
      voice.input.current.result('Open YouTube', true);
      await voiceFrames(tester);
      expect(voice.platform.actions, [
        {'action': 'openApp', 'name': 'youtube'}
      ]);
      expect(store.state.single.messages.last.text, 'Opened youtube.');
      expect(store.state.single.modelId, isNull);
      voice.input.current.result('Explain gravity', true);
      await voiceFrames(tester);
      expect(voice.session.issue, VoiceIssue.noModel);
      expect(find.text('Choose model'), findsOneWidget);
      await tester.tap(find.text('Choose model'));
      await voiceFrames(tester);
      expect(find.text('Models test'), findsOneWidget);
      expect(voice.session.isActive, isFalse);
    } finally {
      await cleanVoice(tester, voice);
    }
  });

  testWidgets('permission recovery is visible and works on a narrow screen',
      (tester) async {
    final voice = VoiceFixture();
    voice.input.available = false;
    voice.input.permission = false;
    await pumpApp(tester, _Conversations([]), _Inference(),
        voice: voice, size: const Size(320, 640));
    try {
      await tester.tap(find.byTooltip('Nomad Voice'));
      await voiceFrames(tester);
      expect(find.text('Voice needs your attention'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      expect(voice.platform.settings, ['permission']);
      voice.input.available = true;
      voice.input.permission = true;
      await tester.tap(find.text('Try again'));
      await voiceFrames(tester);
      expect(find.text('Listening'), findsOneWidget);
    } finally {
      await cleanVoice(tester, voice);
    }
  });

  testWidgets('backgrounding or navigating away closes the microphone',
      (tester) async {
    final voice = VoiceFixture();
    await pumpApp(tester, _Conversations([]), _Inference(), voice: voice);
    try {
      await tester.tap(find.byTooltip('Nomad Voice'));
      await voiceFrames(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(voice.session.isActive, isTrue); // Permission/temporary overlays.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await voiceFrames(tester);
      expect(voice.input.recording, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await voiceFrames(tester);
      expect(voice.session.isActive, isFalse);
      await tester.tap(find.byTooltip('Nomad Voice'));
      await voiceFrames(tester);
      GoRouter.of(tester.element(find.byType(ChatScreen))).push('/settings');
      await voiceFrames(tester);
      expect(voice.input.recording, isFalse);
      expect(voice.session.isActive, isFalse);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await cleanVoice(tester, voice);
    }
  });

  testWidgets(
      'Android invocation routes from Settings and a warm reinvocation starts one new turn',
      (tester) async {
    final voice = VoiceFixture();
    final store = _Conversations([]);
    await pumpApp(tester, store, _Inference(), voice: voice, rootApp: true);
    try {
      final router = tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .routerConfig as GoRouter;
      router.go('/settings');
      await voiceFrames(tester);
      voice.platform.launchEvents
          .add(const AssistantLaunch(id: 'first', prompt: 'Hello assistant'));
      await voiceFrames(tester);
      expect(Uri.parse(router.location).path, '/assistant');
      expect(
          store.state.single.messages
              .where((m) => m.fromUser)
              .map((m) => m.text),
          ['Hello assistant']);
      voice.platform.launchEvents.add(
          const AssistantLaunch(id: 'second', prompt: 'One more question'));
      await voiceFrames(tester);
      expect(
          store.state.single.messages
              .where((m) => m.fromUser)
              .map((m) => m.text),
          ['Hello assistant', 'One more question']);
      expect(voice.input.sessions, isEmpty);
    } finally {
      await cleanVoice(tester, voice);
    }
  });

  testWidgets('typed phone requests act without a language model turn',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      const channel = MethodChannel('com.varun.nomad/assistant');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'success': true, 'message': 'Opening YouTube.'};
      });
      final store = _Conversations([]);
      final inference = _Inference();
      await pumpApp(tester, store, inference,
          platform:
              AssistantPlatformService(channel: channel, isAndroid: true));
      await send(tester, 'Open YouTube');
      expect(calls.single.method, 'executeAction');
      expect(calls.single.arguments, {'action': 'openApp', 'name': 'youtube'});
      expect(find.text('Opening YouTube.'), findsOneWidget);
      expect(inference.histories, isEmpty,
          reason: 'the phone action should answer instead of the model');
      expect(store.state.single.messages.map((m) => m.text),
          ['Open YouTube', 'Opening YouTube.']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'an assistant invocation waits for onboarding before opening the microphone',
      (tester) async {
    final voice = VoiceFixture();
    await pumpApp(tester, _Conversations([]), _Inference(),
        voice: voice, rootApp: true, onboarded: false);
    try {
      final router = tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .routerConfig as GoRouter;
      voice.platform.launchEvents.add(const AssistantLaunch(id: 'onboarding'));
      await voiceFrames(tester);
      expect(router.location, '/onboarding');
      expect(voice.input.initializations, 0);
      router.go('/home');
      await voiceFrames(tester);
      expect(Uri.parse(router.location).path, '/assistant');
      expect(voice.input.sessions, hasLength(1));
    } finally {
      await cleanVoice(tester, voice);
    }
  });
}
