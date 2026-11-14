import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:llamadart/llamadart.dart' hide ChatSession;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../core/services/assistant_platform_service.dart';
import '../../core/services/voice_session_controller.dart';
import '../creations/creations_screen.dart';
import '../../core/services/inference_service.dart';
import '../../core/services/memory_service.dart';
import '../../core/services/model_service.dart';
import '../../core/services/performance_service.dart';
import '../../core/services/phone_actions.dart';
import '../../core/services/search_service.dart';
import '../../core/providers/model_provider.dart';
import '../../core/providers/download_provider.dart';
import '../../core/providers/sidebar_provider.dart';
import '../../core/providers/skill_provider.dart';
import '../../core/models/chat_session.dart';
import '../../core/models/hf_model.dart';
import '../../core/theme/nomad_theme.dart';
import '../../core/widgets/rich_message_renderer.dart';
import '../../core/widgets/nomad_widgets.dart';
import '../../core/widgets/nomad_animations.dart';
import '../../core/constants/responsive.dart';
import '../../core/utils/assistant_command.dart';
import '../../core/utils/message_text.dart';
import '../../core/widgets/voice_status_panel.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/services/html_renderer.dart';
import '../../l10n/app_localizations.dart';

// ============================================================================
// PROVIDERS
// ============================================================================
final chatMessagesProvider =
    StateNotifierProvider<ChatMessagesNotifier, List<ChatMessage>>(
  (ref) => ChatMessagesNotifier(),
);
final conversationsProvider =
    StateNotifierProvider<ConversationsNotifier, List<ChatSession>>(
  (ref) => ConversationsNotifier(),
);

final chatInferenceProvider =
    Provider<InferenceService>((ref) => InferenceService());
final activeConversationIdProvider = Provider<String?>((ref) {
  ref.watch(chatMessagesProvider);
  return ref.read(chatMessagesProvider.notifier).conversationId;
});
final chatRevisionProvider = Provider<int>((ref) {
  ref.watch(chatMessagesProvider);
  return ref.read(chatMessagesProvider.notifier).revision;
});

class ChatMessagesNotifier extends StateNotifier<List<ChatMessage>> {
  ChatMessagesNotifier() : super([]);
  String? _conversationId;
  int _revision = 0;

  String? get conversationId => _conversationId;
  int get revision => _revision;
  String ensureConversationId() => _conversationId ??= const Uuid().v4();

  void openConversation(ChatSession conversation) {
    _conversationId = conversation.id;
    _revision++;
    state = List.of(conversation.messages);
  }

  void addMessage(ChatMessage msg) => state = [...state, msg];
  void updateLastMessage(ChatMessage msg) {
    if (state.isNotEmpty && !state.last.fromUser) {
      state = [...state.sublist(0, state.length - 1), msg];
    } else {
      state = [...state, msg];
    }
  }

  void clear() {
    _conversationId = null;
    _revision++;
    state = [];
  }

  void setMessages(List<ChatMessage> messages) => state = messages;
}

class ConversationsNotifier extends StateNotifier<List<ChatSession>> {
  ConversationsNotifier() : super([]) {
    _loadFromHive();
  }

  void _loadFromHive() {
    final box = Hive.box('chats');
    final chats = <ChatSession>[];
    for (final key in box.keys.toList()) {
      try {
        final v = box.get(key);
        if (v == null) continue;
        chats.add(ChatSession.fromJson(Map<String, dynamic>.from(v as Map)));
      } catch (_) {
        try {
          box.delete(key);
        } catch (_) {}
      }
    }
    chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = chats;
  }

  Future<void> updateConversation(ChatSession conv) async {
    state = [conv, ...state.where((c) => c.id != conv.id)];
    final box = Hive.box('chats');
    await box.put(conv.id, conv.toJson());
  }

  Future<void> deleteConversation(String id) async {
    state = state.where((c) => c.id != id).toList();
    final box = Hive.box('chats');
    await box.delete(id);
  }
}

// ============================================================================
// MAIN CHAT SCREEN
// ============================================================================
class ChatScreen extends ConsumerStatefulWidget {
  final String? modelId;
  final AssistantLaunch? assistantLaunch;
  const ChatScreen({super.key, this.modelId, this.assistantLaunch});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _composerLink = LayerLink();
  final _scrollController = ScrollController();
  bool _isStreaming = false;
  bool _hasText = false;
  bool _isClearingChat = false;
  bool _searchEnabled = false;
  List<String> _attachedImages = [];
  bool _isModelSelectorExpanded = false;
  bool _isModelSelectorClosing = false;
  bool _isModelLoading = false;
  // Inline add-menu panel above the composer.
  bool _isAddMenuOpen = false;
  bool _isAddMenuClosing = false;
  // Creation mode: chip above composer, voice hidden, send routes the
  // typed message through the HTML-creation system prompt.
  bool _isCreationMode = false;
  String _creationType = 'playground';

  late final VoiceSessionController _voice;
  GoRouter? _voiceRouter;
  TextEditingValue? _voiceDraft;
  Future<void>? _messageTask;
  bool _wasLiveMode = false;
  bool get _isLiveMode => _voice.isOwnedBy(this);
  bool get _isLiveMuted => _voice.phase == VoicePhase.paused;

  // Drives the chat-composer <-> live-voice morph (0 = chat, 1 = live).
  late final AnimationController _modeController;
  late final Animation<double> _modeT;

  bool _showTokenSpeed = false;

  /// Randomly selected suggestions for empty state.
  List<String> _suggestions = [];

  static const _suggestionPool = [
    'Explain quantum computing simply',
    'Write me a haiku about space',
    'Help me debug my code',
    'Plan a weekend trip itinerary',
    'Summarize this article for me',
    'Write a poem about the ocean',
    'Explain how neural networks work',
    'Give me a healthy meal plan',
    'Draft a professional email',
    'Tell me a fun science fact',
    'Help me brainstorm app ideas',
    'Write a short story about robots',
  ];

  void _shuffleSuggestions() {
    _suggestions = List<String>.from(_suggestionPool)..shuffle(math.Random());
    _suggestions = _suggestions.take(3).toList();
  }

  /// Running summary of older conversation turns.
  String? _contextSummary;

  final _streamingTextNotifier = ValueNotifier<String>('');
  int _generation = 0;
  StreamIterator<String>? _activeTokens;
  bool _shouldStop = false;

  void _stopGeneration() {
    _shouldStop = true;
    unawaited(_activeTokens?.cancel().catchError((Object error) {
      debugPrint('Could not stop generation: $error');
    }));
  }

  void _startNewChat() {
    ref.read(chatMessagesProvider.notifier).clear();
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  void _conversationChanged() {
    ++_generation;
    _voiceDraft = null;
    _stopGeneration();
    _controller.clear();
    _contextSummary = null;
    _streamingTextNotifier.value = '';
    _shuffleSuggestions();
    setState(() {
      _attachedImages = [];
      _isStreaming = false;
      _isModelLoading = false;
      _isClearingChat = false;
    });
    if (_isLiveMode) {
      unawaited(_exitLiveMode());
    }
  }

  Stream<String> _readTokens(Stream<String> stream, int generation) async* {
    if (!_isCurrent(generation) || _shouldStop) return;
    final iterator = StreamIterator(stream);
    _activeTokens = iterator;
    try {
      while (await iterator.moveNext()) {
        if (!_isCurrent(generation) || _shouldStop) break;
        yield iterator.current;
      }
    } finally {
      await iterator.cancel();
      if (identical(_activeTokens, iterator)) _activeTokens = null;
    }
  }

  Future<void> _saveConversation(
      String id, List<ChatMessage> messages, HFModel? model) async {
    ChatSession? existing;
    for (final conversation in ref.read(conversationsProvider)) {
      if (conversation.id == id) existing = conversation;
    }
    final text = messages.first.text;
    final title = existing?.title ??
        (text.runes.length > 30
            ? '${String.fromCharCodes(text.runes.take(30))}...'
            : text);
    await ref
        .read(conversationsProvider.notifier)
        .updateConversation(ChatSession(
          id: id,
          title: title,
          messages: List.of(messages),
          updatedAt: DateTime.now(),
          modelId: model?.id ?? existing?.modelId,
          projectId: existing?.projectId,
        ));
  }

  /// Summarize older conversation turns to stay within the context window.
  /// Called proactively before each message when context is > 70% full.
  Future<void> _compactContextIfNeeded(
    List<ChatMessage> messages,
    HFModel model,
    int generation,
  ) async {
    final ctxSize = ref.read(chatInferenceProvider).contextSize;
    if (ctxSize <= 0) return;

    // Only compact if we have enough messages and context is filling up
    if (messages.length < 4) return;

    // Estimate tokens: chars / 3.5 (rough UTF-8 token ratio)
    final totalChars = messages.fold<int>(0, (s, m) => s + m.text.length);
    final estimatedTokens = (totalChars / 3.5).round();
    final threshold = (ctxSize * 0.7).round();

    if (estimatedTokens < threshold) return;

    // Keep last 2 exchanges, summarize everything older
    final keepCount = 4; // last 2 user + 2 assistant messages
    final older = messages.length > keepCount
        ? messages.sublist(0, messages.length - keepCount)
        : <ChatMessage>[];

    if (older.isEmpty) return;

    final transcript = older
        .map((m) => '${m.fromUser ? "User" : "Assistant"}: ${m.text}')
        .join('\n');

    final summaryStream = ref.read(chatInferenceProvider).streamChat(
          modelId: model.id,
          prompt: 'Summarize this conversation in 1-2 sentences. '
              'Keep key facts, names, decisions, and user preferences.\n\n$transcript',
          localPath: model.localPath,
          systemPrompt: 'Output only the summary. No preamble or greeting.',
          maxTokens: 128,
          // Quick one-shot queries never need reasoning; skipping thinking
          // keeps compaction fast and the summary free of thinking blocks.
          thinkingBudget: const ThinkingBudget(maxTokens: 0),
        );

    String summary = '';
    await for (final token in _readTokens(summaryStream, generation)) {
      if (!_isCurrent(generation) || _shouldStop) break;
      summary += token;
    }

    summary = stripThinkingTags(summary);

    summary = summary.trim();
    if (summary.isNotEmpty &&
        !summary.startsWith('Error:') &&
        _isCurrent(generation) &&
        !_shouldStop) {
      setState(() => _contextSummary = summary);
    }
  }

  Future<String> _generateWithModel({
    required String prompt,
    required HFModel model,
    required List<Map<String, String>> history,
    required String systemPrompt,
    required StringBuffer buffer,
    required int generation,
    VoiceReply? voiceReply,
    List<String>? imagePaths,
    List<String>? audioPaths,
    List<ToolDefinition>? tools,
  }) async {
    final stream = ref.read(chatInferenceProvider).streamChat(
          modelId: model.id,
          prompt: prompt,
          localPath: model.localPath,
          systemPrompt: systemPrompt,
          history: history,
          maxTokens: voiceReply == null ? 4096 : 512,
          imagePaths: imagePaths,
          audioPaths: audioPaths,
          tools: tools,
          // LFM3-VL-2B thinks by default. Spoken answers skip reasoning: the
          // budget closes the reasoning block immediately so Nomad Voice (and
          // voice quick-search queries) reply without a thinking phase.
          thinkingBudget:
              voiceReply == null ? null : const ThinkingBudget(maxTokens: 0),
        );

    // Throttle UI updates to ~20fps. Pushing the entire growing buffer to the
    // widget tree on every token starves the frame pipeline on low-end
    // devices, which makes animations stutter or freeze and scrolling jank.
    // Coalescing updates keeps the UI smooth without changing the final text.
    int lastUiFlushMs = 0;
    final uiFlushIntervalMs = PerformanceService.instance.streamingIntervalMs;

    await for (final token in _readTokens(stream, generation)) {
      if (!_isCurrent(generation) || _shouldStop) break;
      if (_isModelLoading) setState(() => _isModelLoading = false);
      buffer.write(token);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - lastUiFlushMs >= uiFlushIntervalMs) {
        _streamingTextNotifier.value = buffer.toString();
        lastUiFlushMs = nowMs;
      }
      voiceReply?.addText(token);
    }

    // Flush any tokens withheld by the throttle so the fully streamed text is
    // visible before it is swapped for the persisted message bubble.
    if (!_isCurrent(generation)) return buffer.toString();
    _streamingTextNotifier.value = buffer.toString();

    return buffer.toString();
  }

  String? _extractHtml(String text) {
    final htmlRegex =
        RegExp(r'```html\s*([\s\S]*?)\s*```', caseSensitive: false);
    var match = htmlRegex.firstMatch(text);
    if (match != null) return match.group(1)?.trim();

    final codeRegex = RegExp(r'```\s*([\s\S]*?)\s*```');
    match = codeRegex.firstMatch(text);
    if (match != null) {
      final content = match.group(1)?.trim() ?? '';
      if (content.toLowerCase().contains('<!doctype html>') ||
          content.toLowerCase().contains('<html') ||
          content.toLowerCase().contains('<body')) {
        return content;
      }
    }
    return null;
  }

  Future<void> _sendMessage({VoiceReply? voiceReply, String? voiceAudioPath}) {
    final task = _sendMessageImpl(
        voiceReply: voiceReply, voiceAudioPath: voiceAudioPath);
    _messageTask = task;
    return task.whenComplete(() {
      if (identical(_messageTask, task)) _messageTask = null;
    });
  }

  Future<void> _sendMessageImpl(
      {VoiceReply? voiceReply, String? voiceAudioPath}) async {
    if (voiceReply != null && !voiceReply.isCurrent) return;
    final text = _controller.text.trim();
    final attachedImages = List<String>.from(_attachedImages);
    final attachedAudio = voiceAudioPath ?? '';
    if ((text.isEmpty && attachedImages.isEmpty && attachedAudio.isEmpty) ||
        _isStreaming) return;
    final inference = ref.read(chatInferenceProvider);
    if (inference.isGenerating) {
      if (voiceReply != null) {
        throw const VoiceSessionException(VoiceIssue.audioBusy);
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'The previous response is still stopping. Please try again shortly.'),
      ));
      return;
    }
    // Requests aimed at the phone itself run without a language model, exactly
    // like spoken ones. Ambiguous phrasing ("open the pod bay doors") falls
    // through to the model when Android finds no matching app.
    if (defaultTargetPlatform == TargetPlatform.android &&
        voiceReply == null &&
        attachedImages.isEmpty &&
        attachedAudio.isEmpty &&
        !_isCreationMode) {
      final command = AssistantCommand.parse(text);
      if (command != null &&
          command.response == null &&
          command.action != 'endVoice' &&
          command.action != 'webSearch') {
        final result = await PhoneActions(ref.read(assistantPlatformProvider))
            .run(command);
        if (!mounted) return;
        if (result.success || command.action != 'openApp') {
          await _recordPhoneAction(text, result.message);
          return;
        }
      }
    }

    final selectedModel = ref.read(selectedModelProvider);
    if (selectedModel == null || selectedModel.localPath == null) {
      if (voiceReply != null) {
        if (_voiceDraft?.text.trim().isEmpty ?? true) {
          _voiceDraft = TextEditingValue(text: text);
        }
        throw const VoiceSessionException(VoiceIssue.noModel);
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context)!.noModelSelectedMessage),
      ));
      return;
    }

    final generation = ++_generation;
    final isCreation = _isCreationMode;
    final creationType = _creationType;
    final buffer = StringBuffer();
    setState(() => _isStreaming = true);
    _shouldStop = false;
    _streamingTextNotifier.value = '';
    try {
      if (attachedImages.isNotEmpty) {
        final supportsImages = ModelService.getMmprojUrl(selectedModel.id) !=
                null &&
            await File(selectedModel.localPath!.replaceAll('.gguf', '.mmproj'))
                .exists();
        if (!mounted || !_isCurrent(generation) || _shouldStop) return;
        if (!supportsImages) {
          if (voiceReply != null) {
            throw const VoiceSessionException(VoiceIssue.responseFailed);
          }
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                AppLocalizations.of(context)!.modelDoesNotSupportImageInput),
          ));
          return;
        }
      }
      if (!mounted || !_isCurrent(generation) || _shouldStop) return;
      final chat = ref.read(chatMessagesProvider.notifier);
      final conversationId = chat.ensureConversationId();
      final historyMessages =
          List<ChatMessage>.of(ref.read(chatMessagesProvider));
      final displayText =
          text.isEmpty && attachedAudio.isNotEmpty ? 'Voice message' : text;
      final userMessage = ChatMessage(
          text: displayText,
          fromUser: true,
          time: DateTime.now(),
          imagePaths: attachedImages);
      final requestMessages = [...historyMessages, userMessage];
      chat.addMessage(userMessage);
      _controller.clear();
      if (!context.isDesktop) _focusNode.unfocus();
      setState(() {
        _attachedImages = [];
        _isModelLoading = !inference.isLoaded ||
            inference.modelPath != selectedModel.localPath;
      });
      HapticFeedback.lightImpact();
      _scrollToBottom(smooth: false);

      // Save the prompt before generating. A canceled/switched chat retains its
      // question, and every write uses this request's captured identity/data.
      await _saveConversation(conversationId, requestMessages, selectedModel);
      if (!_isCurrent(generation) || _shouldStop) return;
      if (!PerformanceService.instance.isConstrained) {
        await _compactContextIfNeeded(
            historyMessages, selectedModel, generation);
      }
      if (!_isCurrent(generation) || _shouldStop) return;
      final history = <Map<String, String>>[];
      final hasSummary = _contextSummary?.isNotEmpty ?? false;
      if (hasSummary) {
        history.add({'role': 'assistant', 'content': _contextSummary!});
      }
      final retained = hasSummary && historyMessages.length > 4
          ? historyMessages.sublist(historyMessages.length - 4)
          : historyMessages;
      for (final message in retained) {
        if (message.fromUser || message.text.isNotEmpty) {
          history.add({
            'role': message.fromUser ? 'user' : 'assistant',
            'content': message.text
          });
        }
      }
      final actualPrompt = text.isNotEmpty
          ? text
          : attachedAudio.isNotEmpty
              ? 'Answer the spoken request.'
              : 'Describe this image.';
      final toolsByName = <String, ToolDefinition>{};
      if (!isCreation) {
        for (final tool in ref.read(skillProvider.notifier).getActiveTools()) {
          toolsByName[tool.name] = tool;
        }
        if (_searchEnabled) {
          toolsByName['web_search'] = SearchService.webSearchTool;
        }
      }
      final allTools = toolsByName.values.toList();
      final systemPrompt = isCreation
          ? (creationType == 'widget'
              ? "You are Nomad Widget Creator. The user wants to build a home screen widget. "
                  "Always respond with a complete, self-contained HTML file inside a markdown code block (```html ... ```). "
                  "The widget must be visually striking at small sizes (2x2 or 4x2 cells). "
                  "Use bold solid background colors, large readable text, minimal content. "
                  "Think: clock, weather, counter, status display, countdown, quick note. "
                  "Avoid: scrollable content, tiny text, complex layouts, hover effects. "
                  "Use inline CSS and JavaScript. Make it work well at 300x200 pixels."
              : "You are Nomad Creator. The user wants to build an interactive HTML mini-app. "
                  "Always respond with a complete, self-contained HTML file inside a markdown code block (```html ... ```). "
                  "Use inline CSS and JavaScript. Make it visually polished and interactive.")
          : "You are Nomad, a warm, witty, and genuinely helpful on-device AI companion. "
              "Talk like a thoughtful friend, not a manual: use contractions, natural phrasing, and a relaxed, human tone. "
              "Vary your sentence rhythm, show a little personality and warmth, and keep things concise and to the point. "
              "Avoid robotic boilerplate, over-formality, and dumping long bullet lists unless they're truly the clearest way to help. "
              "Never claim you changed phone settings, opened an app, or set an alarm unless an actual tool result confirms it. "
              "${voiceReply != null ? 'This is a spoken conversation. Answer in the user\'s language, in one to three short, natural sentences. Avoid markdown, lists, code, and reading out URLs. Use web search for current facts instead of guessing. ' : ''}"
              "${MemoryService().getMemoriesForPrompt()}${ref.read(skillProvider.notifier).getActiveSkillInstructions()}";

      String accumulated = await _generateWithModel(
        prompt: actualPrompt,
        model: selectedModel,
        history: history,
        systemPrompt: systemPrompt,
        buffer: buffer,
        generation: generation,
        voiceReply: voiceReply,
        imagePaths: attachedImages,
        audioPaths: attachedAudio.isEmpty ? null : [attachedAudio],
        tools: allTools,
      );

      if (!_isCurrent(generation)) return;
      setState(() => _isModelLoading = false);

      if (voiceReply == null && !_shouldStop && looksTruncated(accumulated)) {
        buffer.clear();
        _streamingTextNotifier.value = accumulated;

        final contHistory = <Map<String, String>>[
          ...history,
          {'role': 'user', 'content': actualPrompt},
          {'role': 'assistant', 'content': accumulated},
        ];

        final cont = await _generateWithModel(
          prompt: 'Continue from where you left off. Do not repeat anything.',
          model: selectedModel,
          history: contHistory,
          systemPrompt: systemPrompt,
          buffer: buffer,
          generation: generation,
          imagePaths: attachedImages.isNotEmpty ? attachedImages : null,
          tools: allTools.isNotEmpty ? allTools : null,
        );

        if (cont.trim().isNotEmpty) {
          accumulated += cont;
        }
      }

      if (!_isCurrent(generation)) return;
      if (accumulated.trim().isEmpty && !_shouldStop) {
        accumulated = 'Error: The model returned no text. Please try again.';
      }
      if (accumulated.trim().isNotEmpty) {
        HapticFeedback.selectionClick();

        // Persist even when stopped - user watched the partial reply, don't discard it.
        final displayText =
            _shouldStop ? '$accumulated\n\n*(stopped)*' : accumulated;
        final reply = ChatMessage(
          text: displayText,
          fromUser: false,
          time: DateTime.now(),
          outputTokPerSec: inference.lastOutputTokPerSec,
          outputTokens: inference.lastOutputTokens,
        );
        ref.read(chatMessagesProvider.notifier).addMessage(reply);
        await _saveConversation(
            conversationId, [...requestMessages, reply], selectedModel);
        if (!mounted || !_isCurrent(generation)) return;
        if (voiceReply != null &&
            accumulated.startsWith('Error:') &&
            !_shouldStop) {
          throw const VoiceSessionException(VoiceIssue.responseFailed);
        }

        if (isCreation) {
          final html = _extractHtml(accumulated);
          if (html != null && html.isNotEmpty && mounted) {
            final chosenType = creationType;
            final creationId = DateTime.now().millisecondsSinceEpoch.toString();
            final title = actualPrompt.runes.length > 30
                ? '${String.fromCharCodes(actualPrompt.runes.take(30))}...'
                : actualPrompt;

            String? screenshotPath;
            if (chosenType == 'widget') {
              try {
                final imageBytes = await HtmlRenderer.renderToImage(
                  html,
                  context: context,
                  size: const Size(400, 300),
                );
                if (imageBytes != null) {
                  final dir = await getApplicationDocumentsDirectory();
                  final file =
                      File('${dir.path}/creation_screenshot_$creationId.png');
                  await file.writeAsBytes(imageBytes);
                  screenshotPath = file.path;
                }
              } catch (_) {}
            }

            final newCreation = Creation(
              id: creationId,
              title: title,
              html: html,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              type: chosenType,
              screenshotPath: screenshotPath,
            );
            if (_isCurrent(generation)) {
              await ref
                  .read(creationsProvider.notifier)
                  .saveCreation(newCreation);
            }
          }
        }
      }
    } catch (error) {
      if (voiceReply != null) rethrow;
      if (mounted && _isCurrent(generation)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not finish or save the response: $error'),
        ));
      }
    } finally {
      if (_isCurrent(generation)) {
        setState(() {
          _isStreaming = false;
          _isModelLoading = false;
        });
      }
    }
  }

  void _scrollToBottom({bool smooth = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        if (smooth) {
          _scrollController.animateTo(
            maxExtent,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          );
        } else {
          _scrollController.jumpTo(maxExtent);
        }
      }
    });
  }

  void _removeImage(int index) {
    setState(() => _attachedImages.removeAt(index));
  }

  Future<void> _pickImages() async {
    final picker = ImagePicker();
    if (PerformanceService.instance.isLowEnd) {
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 70,
        maxWidth: 512,
        maxHeight: 512,
      );
      if (image != null && mounted) {
        setState(() => _attachedImages = [image.path]);
      }
      return;
    }
    final images = await picker.pickMultiImage(
      imageQuality: 70,
      maxWidth: 768,
      maxHeight: 768,
    );
    if (images.isNotEmpty && mounted) {
      setState(() {
        _attachedImages = [
          ..._attachedImages,
          for (final img in images) img.path,
        ];
      });
    }
  }

  /// <= 4 GB phones load models on demand; pre-warm on chat open or composer
  /// focus so the first message does not wait for the full native load.
  /// Best-effort: a failed or unavailable warm-up must never break the screen.
  void _prewarmModel() {
    try {
      final model = ref.read(selectedModelProvider);
      if (model == null || model.localPath == null) return;
      final warming = ref
          .read(chatInferenceProvider)
          .warmUp(model.id, allowLowRam: true);
      warming.catchError((Object _) {});
    } catch (_) {}
  }

  void _composerFocusChanged() {
    if (_focusNode.hasFocus) _prewarmModel();
  }

  /// Warn before selecting Smart/Pro on < 8 GB phones: their allocations can
  /// OOM or crawl there. Loading itself happens on the next message.
  Future<void> _onPickModel(HFModel model) async {
    final proceed = await confirmHeavyModelLoad(
        context, model, PerformanceService.instance.deviceRamGb);
    if (!proceed || !mounted) return;
    ref.read(selectedModelIdProvider.notifier).select(model.id);
    _closeModelSelector();
  }

  void _closeModelSelector() {
    if (!_isModelSelectorExpanded && !_isModelSelectorClosing) return;
    setState(() {
      _isModelSelectorExpanded = false;
      _isModelSelectorClosing = true;
    });
  }

  void _closeAddMenu() {
    if (!_isAddMenuOpen && !_isAddMenuClosing) return;
    setState(() {
      _isAddMenuOpen = false;
      _isAddMenuClosing = true;
    });
  }

  void _toggleAddMenu() {
    HapticFeedback.lightImpact();
    if (_isAddMenuOpen) {
      _closeAddMenu();
    } else {
      setState(() {
        _isAddMenuOpen = true;
        _isAddMenuClosing = false;
        _focusNode.unfocus();
      });
      _closeModelSelector();
    }
  }

  void _enterCreationMode([String type = 'playground']) {
    HapticFeedback.selectionClick();
    setState(() {
      _isCreationMode = true;
      _creationType = type;
      _searchEnabled = false;
    });
    _closeAddMenu();
    _focusNode.requestFocus();
  }

  void _exitCreationMode() {
    HapticFeedback.lightImpact();
    setState(() => _isCreationMode = false);
  }

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = (node, event) {
      final composing = _controller.value.composing;
      if (!context.isDesktop ||
          (event.logicalKey != LogicalKeyboardKey.enter &&
              event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
          HardwareKeyboard.instance.isShiftPressed ||
          (composing.isValid && !composing.isCollapsed)) {
        return KeyEventResult.ignored;
      }
      if (event is KeyDownEvent) _sendMessage();
      return KeyEventResult.handled;
    };
    _modeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
    );
    _modeT = CurvedAnimation(
      parent: _modeController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _voice = ref.read(voiceSessionProvider);
    _voice.addListener(_onVoiceChanged);
    _shuffleSuggestions();
    _controller.addListener(() {
      final hasText = _controller.text.isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
    });
    _focusNode.addListener(_composerFocusChanged);
    _loadPreferences();
    _queueAssistantLaunch(widget.assistantLaunch);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prewarmModel();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission dialogs temporarily make the app inactive. Only a real
    // background transition ends voice; returning never silently opens the mic.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_voice.stop(owner: this));
    }
  }

  void _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(
        () => _showTokenSpeed = prefs.getBool('showTokenSpeed') ?? false,
      );
    }
  }

  Future<void> _toggleLiveMode() async {
    if (_isLiveMode) {
      await _exitLiveMode();
    } else {
      await _enterLiveMode();
    }
  }

  Future<void> _enterLiveMode({String? initialPrompt}) async {
    _focusNode.unfocus();
    _voiceDraft ??= _controller.value;
    _closeAddMenu();
    if (_isLiveMode) await _voice.pause();
    if (_isStreaming) {
      _stopGeneration();
      try {
        await _messageTask;
      } catch (_) {}
    }
    if (!mounted || !_isCurrentVoiceRoute) return;
    setState(() => _isCreationMode = false);
    await _voice.start(
      owner: this,
      onRequest: _handleVoiceRequest,
      cancelRequest: _stopGeneration,
      localeId:
          WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag(),
      initialPrompt: initialPrompt,
      audioTurns:
          ModelService.supportsAudio(ref.read(selectedModelProvider)?.id ?? ''),
    );
  }

  Future<void> _exitLiveMode() async {
    HapticFeedback.lightImpact();
    await _voice.stop(owner: this);
  }

  void _onVoiceChanged() {
    if (!mounted) return;
    final live = _isLiveMode;
    if (live != _wasLiveMode) {
      _wasLiveMode = live;
      if (live) {
        _modeController.forward();
      } else {
        _modeController.reverse();
        final draft = _voiceDraft;
        _voiceDraft = null;
        if (draft != null) {
          _controller.value =
              draft.text.isEmpty && _controller.text.trim().isNotEmpty
                  ? _controller.value
                  : draft;
        }
      }
    }
    setState(() {});
  }

  bool get _isCurrentVoiceRoute {
    final location = _voiceRouter?.location;
    if (location == null) return true;
    final path = Uri.parse(location).path;
    if (widget.assistantLaunch != null) return path == '/assistant';
    if (widget.modelId != null) return path == '/model/${widget.modelId}';
    return path == '/home';
  }

  void _onVoiceRouteChanged() {
    if (_isLiveMode && !_isCurrentVoiceRoute) {
      unawaited(_voice.stop(owner: this));
    }
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assistantLaunch?.id != widget.assistantLaunch?.id) {
      _queueAssistantLaunch(widget.assistantLaunch);
    }
  }

  void _queueAssistantLaunch(AssistantLaunch? launch) {
    if (launch == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.assistantLaunch?.id != launch.id ||
          !_isCurrentVoiceRoute) {
        return;
      }
      if (launch.voice) {
        unawaited(_enterLiveMode(initialPrompt: launch.prompt));
      } else {
        if (launch.prompt != null) _controller.text = launch.prompt!;
        _focusNode.requestFocus();
      }
    });
  }

  Future<void> _handleVoiceRequest(String text, VoiceReply reply) async {
    if (!mounted || !reply.isCurrent) return;
    final audioPath = _voice.lastAudioPath;
    if (text.trim().isEmpty && (audioPath == null || audioPath.isEmpty)) return;
    final command = AssistantCommand.parse(text);
    if (command?.action == 'endVoice') {
      await _exitLiveMode();
      return;
    }
    if (command != null) {
      await _executeVoiceCommand(text, command, reply);
      return;
    }
    _controller.text = text;
    await _sendMessage(voiceReply: reply, voiceAudioPath: audioPath);
  }

  /// Commits a locally executed phone action to the conversation so typed and
  /// spoken requests leave the same visible history, without a model turn.
  Future<void> _recordPhoneAction(String text, String reply) async {
    if (!mounted) return;
    final chat = ref.read(chatMessagesProvider.notifier);
    final conversationId = chat.ensureConversationId();
    final history = List<ChatMessage>.of(ref.read(chatMessagesProvider));
    final question =
        ChatMessage(text: text, fromUser: true, time: DateTime.now());
    final answer =
        ChatMessage(text: reply, fromUser: false, time: DateTime.now());
    chat.addMessage(question);
    chat.addMessage(answer);
    _controller.clear();
    if (!context.isDesktop) _focusNode.unfocus();
    HapticFeedback.selectionClick();
    _scrollToBottom();
    setState(() {});
    await _saveConversation(
      conversationId,
      [...history, question, answer],
      ref.read(selectedModelProvider),
    );
  }

  Future<void> _executeVoiceCommand(
      String text, AssistantCommand command, VoiceReply voiceReply) async {
    final generation = ++_generation;
    _shouldStop = false;
    final model = ref.read(selectedModelProvider);
    final chat = ref.read(chatMessagesProvider.notifier);
    final id = chat.ensureConversationId();
    final question =
        ChatMessage(text: text, fromUser: true, time: DateTime.now());
    final messages = [...ref.read(chatMessagesProvider), question];
    chat.addMessage(question);
    _streamingTextNotifier.value = '';
    setState(() => _isStreaming = true);
    try {
      await _saveConversation(id, messages, model);
      if (!_isCurrent(generation) || _shouldStop || !voiceReply.isCurrent) {
        return;
      }
      final result = command.response ??
          (await PhoneActions(ref.read(assistantPlatformProvider))
                  .run(command))
              .message;
      if (!_isCurrent(generation)) return;
      final answer =
          ChatMessage(text: result, fromUser: false, time: DateTime.now());
      chat.addMessage(answer);
      await _saveConversation(id, [...messages, answer], model);
      voiceReply.addText(result);
      if (_isCurrent(generation)) _scrollToBottom();
    } finally {
      if (_isCurrent(generation)) setState(() => _isStreaming = false);
    }
  }

  void _toggleLiveMute() {
    HapticFeedback.selectionClick();
    if (_isLiveMuted) {
      unawaited(_voice.retry());
    } else {
      unawaited(_voice.pause());
    }
  }

  Future<void> _openVoiceSettings(String kind) async {
    try {
      final opened =
          await ref.read(assistantPlatformProvider).openSettings(kind);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Open your device settings to configure microphone access and speech services.'),
        ));
      }
    } catch (_) {}
  }

  Widget _buildLiveCenter() {
    final responding = _voice.isResponding;
    final retry =
        _voice.phase == VoicePhase.paused || _voice.phase == VoicePhase.error;
    return IconButton(
      tooltip: responding
          ? 'Interrupt and listen'
          : retry
              ? 'Resume listening'
              : 'Finish speaking',
      onPressed: responding
          ? _voice.interrupt
          : retry
              ? _voice.retry
              : _voice.finishListening,
      icon: Icon(responding
          ? Icons.stop_rounded
          : retry
              ? Icons.mic_off_rounded
              : Icons.mic_rounded),
      color: const Color(0xFF183F78),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (!identical(router, _voiceRouter)) {
      _voiceRouter?.routerDelegate.removeListener(_onVoiceRouteChanged);
      _voiceRouter = router;
      router?.routerDelegate.addListener(_onVoiceRouteChanged);
    }
    final brightness = Theme.of(context).brightness;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            brightness == Brightness.dark ? Brightness.light : Brightness.dark,
      ),
    );
  }

  @override
  void dispose() {
    ++_generation;
    _stopGeneration();
    _voice.removeListener(_onVoiceChanged);
    _voiceRouter?.routerDelegate.removeListener(_onVoiceRouteChanged);
    unawaited(_voice.stop(owner: this));
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _controller.dispose();
    _focusNode.removeListener(_composerFocusChanged);
    _focusNode.dispose();
    _streamingTextNotifier.dispose();
    _modeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(chatRevisionProvider, (previous, next) {
      if (previous != next) _conversationChanged();
    });
    final mediaQuery = MediaQuery.of(context);
    final topPadding = mediaQuery.padding.top;
    final keyboardHeight = mediaQuery.viewInsets.bottom;
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;

    final headerTop = topPadding + (context.isDesktop ? 24.0 : 16.0);
    final inputBottom = keyboardHeight > 0
        ? keyboardHeight + 16
        : MediaQuery.of(context).padding.bottom +
            (context.isDesktop ? 24.0 : 30.0);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: nomad.background,
        resizeToAvoidBottomInset: false,
        body: LayoutBuilder(builder: (context, constraints) {
          final contentInset =
              math.max(20.0, (constraints.maxWidth - ContentWidths.chat) / 2);
          return GestureDetector(
            onTap: () {
              FocusScope.of(context).unfocus();
              if (_isModelSelectorExpanded || _isAddMenuOpen) {
                if (_isModelSelectorExpanded) _closeModelSelector();
                if (_isAddMenuOpen) _closeAddMenu();
              }
            },
            behavior: HitTestBehavior.translucent,
            child: Stack(
              children: [
                Positioned.fill(
                  child: NomadBackdrop(
                    state: _isModelLoading
                        ? BackdropState.loading
                        : _isStreaming
                            ? BackdropState.streaming
                            : BackdropState.idle,
                  ),
                ),
                Positioned(
                  left: contentInset,
                  right: contentInset,
                  top: headerTop + 64,
                  bottom: inputBottom,
                  child: Row(
                    key: const ValueKey('chat-column'),
                    children: [
                      Expanded(
                        flex: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned.fill(
                                    child: Consumer(
                                      builder: (context, ref, _) {
                                        final messages =
                                            ref.watch(chatMessagesProvider);
                                        return AnimatedOpacity(
                                          opacity: _isClearingChat ? 0.0 : 1.0,
                                          duration:
                                              const Duration(milliseconds: 180),
                                          child: _AdaptiveShaderMask(
                                            shaderCallback: (rect) {
                                              return const LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                                  Colors.transparent,
                                                  Colors.white,
                                                  Colors.white,
                                                  Colors.transparent,
                                                ],
                                                stops: [
                                                  0.0,
                                                  0.06,
                                                  0.94,
                                                  1.0,
                                                ],
                                              ).createShader(rect);
                                            },
                                            blendMode: BlendMode.dstIn,
                                            child: messages.isEmpty
                                                ? _buildEmptyState(context)
                                                : ListView.builder(
                                                    controller:
                                                        _scrollController,
                                                    padding:
                                                        const EdgeInsets.only(
                                                            top: 8),
                                                    itemCount: messages.length +
                                                        (_isStreaming ? 1 : 0),
                                                    scrollCacheExtent:
                                                        const ScrollCacheExtent
                                                            .pixels(600),
                                                    addAutomaticKeepAlives:
                                                        false,
                                                    addRepaintBoundaries: true,
                                                    physics:
                                                        const BouncingScrollPhysics(),
                                                    itemBuilder:
                                                        (context, index) {
                                                      if (index ==
                                                          messages.length) {
                                                        return _buildStreamingBubble(
                                                            true);
                                                      }
                                                      final msg =
                                                          messages[index];
                                                      final isLast = index ==
                                                              messages.length -
                                                                  1 &&
                                                          !_isStreaming;
                                                      return _buildBubble(
                                                        msg,
                                                        isLast: isLast,
                                                      );
                                                    },
                                                  ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(height: 10),
                                if (_attachedImages.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: SizedBox(
                                      height: 80,
                                      child: ListView.builder(
                                        scrollDirection: Axis.horizontal,
                                        itemCount: _attachedImages.length,
                                        itemBuilder: (context, index) =>
                                            Padding(
                                          padding:
                                              const EdgeInsets.only(right: 8),
                                          child: Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                child: Image.file(
                                                  File(_attachedImages[index]),
                                                  width: 72,
                                                  height: 72,
                                                  fit: BoxFit.cover,
                                                  cacheWidth: 72,
                                                  cacheHeight: 72,
                                                ),
                                              ),
                                              Positioned(
                                                top: -6,
                                                right: -6,
                                                child: GestureDetector(
                                                  onTap: () =>
                                                      _removeImage(index),
                                                  child: Container(
                                                    width: 22,
                                                    height: 22,
                                                    decoration: BoxDecoration(
                                                      color: nomad.surface,
                                                      shape: BoxShape.circle,
                                                      border: Border.all(
                                                        color: nomad.border,
                                                        width: 1,
                                                      ),
                                                    ),
                                                    child: Icon(
                                                      Icons.close,
                                                      size: 14,
                                                      color:
                                                          nomad.textSecondary,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (_isCreationMode && !_isAddMenuOpen)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: _CreationChip(
                                        onDismiss: _exitCreationMode,
                                        creationType: _creationType),
                                  ),
                                if (_isLiveMode)
                                  VoiceStatusPanel(
                                    session: _voice,
                                    modelLoading: _isModelLoading,
                                    searchEnabled: _searchEnabled,
                                    onSearchChanged: (value) =>
                                        setState(() => _searchEnabled = value),
                                    onTypeInstead: _exitLiveMode,
                                    onChooseModel: () =>
                                        context.push('/settings/models'),
                                    onOpenSettings: _openVoiceSettings,
                                  ),
                              ],
                            ),
                            CompositedTransformTarget(
                              link: _composerLink,
                              child: ValueListenableBuilder<double>(
                                valueListenable: _voice.soundLevel,
                                builder: (context, level, _) => LayoutBuilder(
                                  builder: (context, constraints) {
                                    final rawLevel = level.clamp(-50.0, 50.0);
                                    final normalizedLevel = math
                                        .max(0.0, (rawLevel + 30.0) / 50.0)
                                        .clamp(0.0, 1.0);

                                    final liveMaxWidth =
                                        constraints.maxWidth - 120.0;
                                    final audioWidth = _isLiveMuted
                                        ? 48.0
                                        : 48.0 +
                                            (normalizedLevel *
                                                (liveMaxWidth - 48.0));

                                    return AnimatedBuilder(
                                      animation: _modeT,
                                      builder: (context, _) {
                                        final mt = _modeT.value;
                                        // The chat<->live morph is driven by _modeT;
                                        // the audio-reactive width is smoothed quickly
                                        // so the pill stays snappy while listening.
                                        return TweenAnimationBuilder<double>(
                                          duration:
                                              const Duration(milliseconds: 120),
                                          curve: Curves.easeOut,
                                          tween: Tween<double>(
                                              begin: audioWidth,
                                              end: audioWidth),
                                          builder: (context, smoothAudio, __) {
                                            final currentWidth = constraints
                                                    .maxWidth +
                                                (smoothAudio -
                                                        constraints.maxWidth) *
                                                    mt;
                                            final btnT = ((mt - 0.35) / 0.65)
                                                .clamp(0.0, 1.0);

                                            final circleLeft =
                                                (constraints.maxWidth -
                                                        currentWidth) /
                                                    2;

                                            return SizedBox(
                                              width: constraints.maxWidth,
                                              child: Stack(
                                                alignment: Alignment.center,
                                                clipBehavior: Clip.none,
                                                children: [
                                                  SizedBox(
                                                    width: currentWidth,
                                                    child: AnimatedContainer(
                                                      key: const ValueKey(
                                                          'chat-composer'),
                                                      duration: const Duration(
                                                          milliseconds: 460),
                                                      curve:
                                                          Curves.easeOutCubic,
                                                      height: _isLiveMode
                                                          ? 48.0
                                                          : null,
                                                      constraints: _isLiveMode
                                                          ? null
                                                          : const BoxConstraints(
                                                              minHeight: 60,
                                                              maxHeight: 164),
                                                      decoration: _isLiveMode
                                                          ? BoxDecoration(
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                          100),
                                                              gradient:
                                                                  const LinearGradient(
                                                                begin: Alignment
                                                                    .topCenter,
                                                                end: Alignment
                                                                    .bottomCenter,
                                                                colors: [
                                                                  Colors.white,
                                                                  Color(
                                                                      0xFF86A8E7)
                                                                ],
                                                              ),
                                                            )
                                                          : BoxDecoration(
                                                              color: nomad
                                                                  .surface
                                                                  .withValues(
                                                                      alpha:
                                                                          0.92),
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                      NomadRadii
                                                                          .card),
                                                              border: Border.all(
                                                                  color: nomad
                                                                      .border,
                                                                  width: 1),
                                                            ),
                                                      clipBehavior:
                                                          Clip.antiAlias,
                                                      child: _isLiveMode
                                                          ? _buildLiveCenter()
                                                          : OverflowBox(
                                                              minWidth:
                                                                  constraints
                                                                      .maxWidth,
                                                              maxWidth:
                                                                  constraints
                                                                      .maxWidth,
                                                              fit: OverflowBoxFit
                                                                  .deferToChild,
                                                              child:
                                                                  AnimatedBuilder(
                                                                animation:
                                                                    _modeController,
                                                                builder:
                                                                    (context,
                                                                        child) {
                                                                  final v =
                                                                      _modeController
                                                                          .value;
                                                                  final cv = (1.0 -
                                                                          v /
                                                                              0.5)
                                                                      .clamp(
                                                                          0.0,
                                                                          1.0);
                                                                  return Opacity(
                                                                    opacity: Curves
                                                                        .easeOut
                                                                        .transform(
                                                                            cv),
                                                                    child: Transform
                                                                        .scale(
                                                                      scale: 0.95 +
                                                                          0.05 *
                                                                              cv,
                                                                      alignment:
                                                                          Alignment
                                                                              .centerLeft,
                                                                      child:
                                                                          child,
                                                                    ),
                                                                  );
                                                                },
                                                                child:
                                                                    ExcludeFocus(
                                                                  excluding:
                                                                      _isLiveMode,
                                                                  child:
                                                                      IgnorePointer(
                                                                    ignoring:
                                                                        _isLiveMode,
                                                                    child:
                                                                        Padding(
                                                                      padding: const EdgeInsets.only(
                                                                          left:
                                                                              6,
                                                                          right:
                                                                              6,
                                                                          top:
                                                                              6,
                                                                          bottom:
                                                                              6),
                                                                      child:
                                                                          Row(
                                                                        crossAxisAlignment:
                                                                            CrossAxisAlignment.center,
                                                                        children: [
                                                                          _ComposerAddButton(
                                                                            isOpen:
                                                                                _isAddMenuOpen || _isCreationMode,
                                                                            onTap: _isCreationMode
                                                                                ? _exitCreationMode
                                                                                : _toggleAddMenu,
                                                                          ),
                                                                          const SizedBox(
                                                                              width: 10),
                                                                          Expanded(
                                                                            child:
                                                                                Theme(
                                                                              data: Theme.of(context).copyWith(
                                                                                inputDecorationTheme: const InputDecorationTheme(
                                                                                  border: InputBorder.none,
                                                                                  enabledBorder: InputBorder.none,
                                                                                  focusedBorder: InputBorder.none,
                                                                                ),
                                                                              ),
                                                                              child: TextField(
                                                                                controller: _controller,
                                                                                focusNode: _focusNode,
                                                                                minLines: 1,
                                                                                maxLines: 4,
                                                                                keyboardType: TextInputType.multiline,
                                                                                textInputAction: TextInputAction.newline,
                                                                                style: textTheme.bodyMedium,
                                                                                decoration: InputDecoration(
                                                                                  hintText: _isCreationMode ? 'Describe your creation…' : 'Ask anything',
                                                                                  hintStyle: textTheme.bodyMedium?.copyWith(color: nomad.textSecondary),
                                                                                  filled: false,
                                                                                  fillColor: Colors.transparent,
                                                                                  border: InputBorder.none,
                                                                                  enabledBorder: InputBorder.none,
                                                                                  focusedBorder: InputBorder.none,
                                                                                  errorBorder: InputBorder.none,
                                                                                  disabledBorder: InputBorder.none,
                                                                                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                                                                                  isDense: true,
                                                                                  counterText: '',
                                                                                ),
                                                                                onSubmitted: (_) => _sendMessage(),
                                                                              ),
                                                                            ),
                                                                          ),
                                                                          if (_searchEnabled &&
                                                                              !_isCreationMode)
                                                                            _ComposerIconButton(
                                                                              tooltip: 'Web search on',
                                                                              icon: Icons.language_rounded,
                                                                              isActive: true,
                                                                              onTap: () {
                                                                                HapticFeedback.lightImpact();
                                                                                setState(() => _searchEnabled = false);
                                                                              },
                                                                            ),
                                                                          if (_searchEnabled &&
                                                                              !_isCreationMode)
                                                                            const SizedBox(width: 6),
                                                                          if (!_isCreationMode)
                                                                            _ComposerIconButton(
                                                                              tooltip: 'Nomad Voice',
                                                                              svgAsset: 'assets/images/mic.svg',
                                                                              onTap: () {
                                                                                HapticFeedback.mediumImpact();
                                                                                _toggleLiveMode();
                                                                              },
                                                                            ),
                                                                          if (!_isCreationMode)
                                                                            const SizedBox(width: 6),
                                                                          NomadSendButton(
                                                                            onTap:
                                                                                _sendMessage,
                                                                            onStop:
                                                                                _stopGeneration,
                                                                            isEnabled:
                                                                                _hasText || _attachedImages.isNotEmpty,
                                                                            isStreaming:
                                                                                _isStreaming,
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                    ),
                                                  ),
                                                  Positioned(
                                                    left: circleLeft - 60,
                                                    top: 0,
                                                    bottom: 0,
                                                    child: IgnorePointer(
                                                      ignoring: !_isLiveMode,
                                                      child: ExcludeFocus(
                                                        excluding: !_isLiveMode,
                                                        child: Opacity(
                                                          opacity: btnT,
                                                          child:
                                                              Transform.scale(
                                                            scale: 0.7 +
                                                                0.3 * btnT,
                                                            child: SizedBox(
                                                              width: 48,
                                                              child: Center(
                                                                child:
                                                                    _ComposerIconButton(
                                                                  tooltip: _isLiveMuted
                                                                      ? 'Resume voice'
                                                                      : 'Pause voice',
                                                                  svgAsset:
                                                                      'assets/images/mic.svg',
                                                                  isActive:
                                                                      _isLiveMuted,
                                                                  onTap:
                                                                      _toggleLiveMute,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  Positioned(
                                                    right: circleLeft - 60,
                                                    top: 0,
                                                    bottom: 0,
                                                    child: IgnorePointer(
                                                      ignoring: !_isLiveMode,
                                                      child: ExcludeFocus(
                                                        excluding: !_isLiveMode,
                                                        child: Opacity(
                                                          opacity: btnT,
                                                          child:
                                                              Transform.scale(
                                                            scale: 0.7 +
                                                                0.3 * btnT,
                                                            child: SizedBox(
                                                              width: 48,
                                                              child: Center(
                                                                child:
                                                                    _ComposerIconButton(
                                                                  tooltip:
                                                                      'End voice',
                                                                  icon: Icons
                                                                      .close_rounded,
                                                                  onTap:
                                                                      _exitLiveMode,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (_isModelSelectorExpanded || _isModelSelectorClosing)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Container(
                        color: nomad.background.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                if (_isAddMenuOpen || _isAddMenuClosing)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Container(
                        color: nomad.background.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                if (_isAddMenuOpen || _isAddMenuClosing)
                  Positioned(
                    left: contentInset,
                    right: contentInset,
                    bottom: inputBottom,
                    child: CompositedTransformFollower(
                      link: _composerLink,
                      showWhenUnlinked: false,
                      targetAnchor: Alignment.topLeft,
                      followerAnchor: Alignment.bottomLeft,
                      offset: const Offset(0, -12),
                      child: _AddMenuPanel(
                        isOpen: _isAddMenuOpen,
                        onCloseComplete: () {
                          if (mounted) {
                            setState(() => _isAddMenuClosing = false);
                          }
                        },
                        onPickFile: () {
                          _closeAddMenu();
                          _pickImages();
                        },
                        onSelectCreationType: (type) =>
                            _enterCreationMode(type),
                        searchEnabled: _searchEnabled,
                        onToggleSearch: () {
                          HapticFeedback.lightImpact();
                          setState(() => _searchEnabled = !_searchEnabled);
                          _closeAddMenu();
                        },
                        isCreationMode: _isCreationMode,
                      ),
                    ),
                  ),
                Positioned(
                  left: contentInset,
                  top: headerTop,
                  child: BouncyTap(
                    tooltip: AppLocalizations.of(context)!.chatHistory,
                    onTap: () {
                      if (context.isDesktop) {
                        ref.read(sidebarOpenProvider.notifier).toggle();
                      } else {
                        context.push('/history');
                      }
                    },
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                          child: SvgPicture.asset(
                        'assets/images/menu-02.svg',
                        width: 22,
                        height: 22,
                        colorFilter: ColorFilter.mode(
                          nomad.textPrimary,
                          BlendMode.srcIn,
                        ),
                      )),
                    ),
                  ),
                ),
                Consumer(
                  builder: (context, ref, child) {
                    final selectedModel = ref.watch(selectedModelProvider);
                    final downloadedModels = ref
                        .watch(downloadProvider)
                        .where(
                            (m) => m.downloaded && !m.id.contains('creative'))
                        .toList();
                    final modelName = selectedModel?.name ?? '';

                    String suffix = '';
                    if (modelName.toLowerCase().contains('nano')) {
                      suffix = ' Nano';
                    } else if (modelName.toLowerCase().contains('lite')) {
                      suffix = ' Lite';
                    } else if (modelName.toLowerCase().contains('creative')) {
                      suffix = ' Creative';
                    } else if (modelName.toLowerCase().contains('steady')) {
                      suffix = ' Steady';
                    } else if (modelName.toLowerCase().contains('smart')) {
                      suffix = ' Smart';
                    } else if (modelName.toLowerCase().contains('pro')) {
                      suffix = ' Pro';
                    }

                    final hasMultiple = downloadedModels.length > 1;

                    final otherModels = downloadedModels
                        .where((m) => m.id != selectedModel?.id)
                        .toList();

                    return Positioned(
                      left: contentInset + 56,
                      right: contentInset + 56,
                      top: headerTop,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          BouncyTap(
                            tooltip: AppLocalizations.of(context)!.modelPicker,
                            onTap: hasMultiple
                                ? () {
                                    if (_isModelSelectorExpanded) {
                                      _closeModelSelector();
                                    } else {
                                      setState(() {
                                        _isModelSelectorExpanded = true;
                                        _isModelSelectorClosing = false;
                                      });
                                    }
                                  }
                                : () => context.push('/settings/models'),
                            scaleDown: 0.95,
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 48),
                              alignment: Alignment.centerLeft,
                              child: Row(children: [
                                Flexible(
                                    child: Text(
                                  'Nomad$suffix',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.headlineMedium,
                                )),
                                if (hasMultiple) ...[
                                  const SizedBox(width: 4),
                                  Icon(
                                    _isModelSelectorExpanded
                                        ? Icons.keyboard_arrow_up_rounded
                                        : Icons.keyboard_arrow_down_rounded,
                                    size: 18,
                                    color: nomad.textSecondary,
                                  ),
                                ],
                              ]),
                            ),
                          ),
                          if ((_isModelSelectorExpanded ||
                                  _isModelSelectorClosing) &&
                              otherModels.isNotEmpty)
                            _ModelPickerDropdown(
                              models: otherModels,
                              isOpen: _isModelSelectorExpanded,
                              onCloseComplete: () {
                                if (mounted) {
                                  setState(
                                      () => _isModelSelectorClosing = false);
                                }
                              },
                              onSelect: _onPickModel,
                            ),
                        ],
                      ),
                    );
                  },
                ),
                if (ref.watch(chatMessagesProvider).isNotEmpty)
                  Positioned(
                    right: contentInset,
                    top: headerTop,
                    child: _AnimatedPencilButton(onTap: _startNewChat),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : (hour < 17 ? 'Good afternoon' : 'Good evening');

    final suggestions = _suggestions;

    if (_isModelLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PulseText(
              text: 'Loading model',
              style: textTheme.bodyMedium?.copyWith(
                color: nomad.textSecondary,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      );
    }

    return BouncyFadeSlide(
      duration: NomadDurations.slow,
      slideOffset: 24,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                greeting,
                style: textTheme.displaySmall?.copyWith(
                  color: nomad.textPrimary,
                ),
              ),
              const SizedBox(height: 32),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: suggestions.map((s) {
                  return BouncyTap(
                    onTap: () {
                      _controller.text = s;
                      setState(() => _hasText = true);
                      _sendMessage();
                    },
                    scaleDown: 0.95,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: nomad.surface.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: nomad.border,
                          width: 1,
                        ),
                      ),
                      child: Text(
                        s,
                        style: textTheme.bodySmall?.copyWith(
                          color: nomad.textPrimary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(ChatMessage msg, {bool isLast = false}) {
    final isUser = msg.fromUser;
    final bottomPadding = isLast ? 0.0 : 10.0;
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final isError = !isUser && msg.text.startsWith('Error:');

    final hasThinking = !isUser &&
        (msg.text.contains('<think>') ||
            msg.text.contains('<|channel>thought') ||
            msg.text.contains('<|think|>'));
    final thinkingContent = hasThinking ? extractThinking(msg.text) : '';

    Widget bubbleContent;
    if (!isUser) {
      var displayText = msg.text;
      if (hasThinking) {
        displayText = stripThinkingTags(displayText);
      }

      final textContent = RichMessageRenderer(
        text: displayText.isEmpty ? msg.text : displayText,
        isUser: false,
      );

      bubbleContent = textContent;
    } else {
      final textContent = Text(
        msg.text,
        style: textTheme.bodyMedium?.copyWith(
          color: nomad.textPrimary,
          height: 1.22,
        ),
      );

      bubbleContent = Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (msg.imagePaths.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: msg.imagePaths.map((path) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: Image.file(
                      File(path),
                      width: 180,
                      height: 180,
                      fit: BoxFit.cover,
                      cacheWidth: 180,
                      cacheHeight: 180,
                    ),
                  );
                }).toList(),
              ),
            ),
          textContent,
        ],
      );
    }

    final bubble = !isUser
        ? RepaintBoundary(
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasThinking)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildThinkingBadge(
                        nomad: nomad,
                        textTheme: textTheme,
                      ),
                    ),
                  if (hasThinking && thinkingContent.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildThinkingProcess(
                        content: thinkingContent,
                        nomad: nomad,
                        textTheme: textTheme,
                      ),
                    ),
                  bubbleContent,
                  if (!isUser)
                    _buildMessageFooter(
                      msg,
                      nomad: nomad,
                      textTheme: textTheme,
                      isError: isError,
                      showTokenSpeed: _showTokenSpeed,
                    ),
                  if (isError)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: BouncyTap(
                        onTap: _isStreaming ? null : () => _regenerate(msg),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: nomad.textPrimary.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.refresh,
                                size: 14,
                                color: nomad.textPrimary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                AppLocalizations.of(context)!.retry,
                                style: textTheme.labelLarge?.copyWith(
                                  color: nomad.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          )
        : RepaintBoundary(
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomPadding),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: ShapeDecoration(
                        color: nomad.surfaceSecondary,
                        shape: const ContinuousRectangleBorder(
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(18),
                            topRight: Radius.circular(18),
                            bottomLeft: Radius.circular(18),
                            bottomRight: Radius.circular(4),
                          ),
                        ),
                        shadows: [
                          BoxShadow(
                            color: nomad.textPrimary.withValues(alpha: 0.03),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: bubbleContent,
                    ),
                  ),
                ],
              ),
            ),
          );

    return BouncyFadeSlide(
      duration: NomadDurations.normal,
      slideOffset: 12,
      child: GestureDetector(onLongPress: null, child: bubble),
    );
  }

  void _regenerate(ChatMessage msg) {
    if (_isStreaming || ref.read(chatInferenceProvider).isGenerating) return;
    final messages = ref.read(chatMessagesProvider);
    final msgIndex = messages.indexOf(msg);
    if (msgIndex < 0) return;

    // Find the last user message before this assistant message
    final earlierMessages = messages.sublist(0, msgIndex);
    final userMsgIndex = earlierMessages.lastIndexWhere((m) => m.fromUser);
    if (userMsgIndex < 0) return; // No user message to regenerate from
    final userMsg = earlierMessages[userMsgIndex];

    ref
        .read(chatMessagesProvider.notifier)
        .setMessages(earlierMessages.sublist(0, userMsgIndex));
    _controller.text = userMsg.text;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: userMsg.text.length),
    );
    setState(() => _hasText = true);
    _sendMessage();
  }

  Widget _buildMessageFooter(
    ChatMessage msg, {
    required NomadColorsExtension nomad,
    required TextTheme textTheme,
    required bool isError,
    bool showTokenSpeed = false,
  }) {
    final hasStats = showTokenSpeed &&
        !isError &&
        (msg.outputTokPerSec > 0 || msg.outputTokens > 0);
    final tg = msg.outputTokPerSec > 0
        ? '${msg.outputTokPerSec.toStringAsFixed(1)} t/s'
        : null;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          BouncyTap(
            tooltip: 'Copy message',
            onTap: () {
              Clipboard.setData(ClipboardData(text: msg.text));
              HapticFeedback.lightImpact();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    AppLocalizations.of(context)!.copiedToClipboard,
                    style: textTheme.bodySmall,
                  ),
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(NomadRadii.snackBar),
                  ),
                  margin: const EdgeInsets.all(20),
                ),
              );
            },
            scaleDown: 0.9,
            child: SizedBox.square(
              dimension: 48,
              child: Center(
                  child: Icon(
                Icons.content_copy,
                size: 18,
                color: nomad.textPrimary,
              )),
            ),
          ),
          const SizedBox(width: 10),
          BouncyTap(
            tooltip: 'Regenerate response',
            onTap: _isStreaming ? null : () => _regenerate(msg),
            scaleDown: 0.9,
            child: SizedBox.square(
              dimension: 48,
              child: Center(
                  child:
                      Icon(Icons.refresh, size: 18, color: nomad.textPrimary)),
            ),
          ),
          if (hasStats) ...[
            const SizedBox(width: 10),
            Text(
              '${tg != null ? 'Output Speed: $tg' : ''}${msg.outputTokens > 0 ? '  \u2022  ${msg.outputTokens} tok' : ''}',
              style: textTheme.labelMedium?.copyWith(
                color: nomad.textSecondary.withValues(alpha: 0.5),
                fontSize: 10,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildThinkingBadge({
    required NomadColorsExtension nomad,
    required TextTheme textTheme,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: nomad.textPrimary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.psychology, size: 12, color: nomad.textSecondary),
          const SizedBox(width: 5),
          Text(
            AppLocalizations.of(context)!.reasoned,
            style: textTheme.labelLarge?.copyWith(
              color: nomad.textSecondary,
              fontWeight: FontWeight.w400,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThinkingProcess({
    required String content,
    required NomadColorsExtension nomad,
    required TextTheme textTheme,
  }) {
    return _ThinkingProcessBlock(
      content: content,
      nomad: nomad,
      textTheme: textTheme,
    );
  }

  Widget _buildStreamingBubble(bool isLast) {
    final textTheme = Theme.of(context).textTheme;
    return RepaintBoundary(
      child: Padding(
        padding: EdgeInsets.only(bottom: isLast ? 0.0 : 10.0),
        child: ValueListenableBuilder<String>(
          valueListenable: _streamingTextNotifier,
          builder: (context, streamingText, _) {
            if (streamingText.isEmpty) {
              return const NomadThinkingIndicator();
            }
            final cleanText = stripThinkingTags(streamingText);
            if (cleanText.isEmpty) {
              return const SizedBox.shrink();
            }
            return Text(
              cleanText,
              style: textTheme.bodyMedium?.copyWith(height: 1.45),
            );
          },
        ),
      ),
    );
  }
}

/// ShaderMask creates an offscreen layer while the conversation scrolls.
/// Keep the Figma edge fade on capable devices and skip that layer on phones
/// where it competes with inference for frame time.
class _AdaptiveShaderMask extends StatelessWidget {
  const _AdaptiveShaderMask({
    required this.shaderCallback,
    required this.blendMode,
    required this.child,
  });

  final ShaderCallback shaderCallback;
  final BlendMode blendMode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (PerformanceService.instance.isConstrained) return child;
    return ShaderMask(
      shaderCallback: shaderCallback,
      blendMode: blendMode,
      child: child,
    );
  }
}

class _LiveWaveIndicator extends StatefulWidget {
  const _LiveWaveIndicator();

  @override
  State<_LiveWaveIndicator> createState() => _LiveWaveIndicatorState();
}

class _LiveWaveIndicatorState extends State<_LiveWaveIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(5, (index) {
            final t = (_controller.value + index * 0.2) % 1.0;
            final height = 8 + 16 * math.sin(t * math.pi);
            return Container(
              width: 4,
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: nomad.textPrimary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(999),
              ),
            );
          }),
        );
      },
    );
  }
}

class _ComposerAddButton extends StatelessWidget {
  final bool isOpen;
  final VoidCallback onTap;

  const _ComposerAddButton({required this.isOpen, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return BouncyTap(
      tooltip: isOpen ? 'Close' : 'Add',
      onTap: onTap,
      scaleDown: 0.86,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: isOpen
              ? nomad.textPrimary.withValues(alpha: 0.08)
              : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: AnimatedRotation(
            duration: const Duration(milliseconds: 180),
            curve: Curves.linear,
            turns: isOpen ? 0.125 : 0.0,
            child: SvgPicture.asset(
              'assets/images/plus.svg',
              width: 26,
              height: 26,
              colorFilter: ColorFilter.mode(nomad.textPrimary, BlendMode.srcIn),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddMenuPanel extends StatefulWidget {
  final VoidCallback onPickFile;
  final void Function(String type) onSelectCreationType;
  final VoidCallback onToggleSearch;
  final bool searchEnabled;
  final bool isCreationMode;
  final bool isOpen;
  final VoidCallback? onCloseComplete;

  const _AddMenuPanel({
    required this.onPickFile,
    required this.onSelectCreationType,
    required this.onToggleSearch,
    required this.searchEnabled,
    required this.isCreationMode,
    required this.isOpen,
    this.onCloseComplete,
  });

  @override
  State<_AddMenuPanel> createState() => _AddMenuPanelState();
}

class _AddMenuPanelState extends State<_AddMenuPanel>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isOpening = true;
  bool _isCreationsExpanded = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 480),
      vsync: this,
    );
    _isOpening = widget.isOpen;
    if (widget.isOpen) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_AddMenuPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isOpen && !widget.isOpen) {
      _isOpening = false;
      _controller.reverse().then((_) {
        widget.onCloseComplete?.call();
      });
    } else if (!oldWidget.isOpen && widget.isOpen) {
      _isOpening = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Cascade animation: bottom item slides up first from the composer,
  /// then the middle item from the bottom one, then the top item from
  /// the middle. On close, reverse: top slides down first.
  /// The top item (last to appear on open) gets a subtle bounce.
  Widget _cascadeItem(int visualIndex, Widget child) {
    final itemCount = 3;
    // visualIndex 0 = topmost, itemCount-1 = bottommost (closest to composer)
    // On open: bottom animates first → reverse visual order
    // On close: top animates first → forward visual order

    // For a 3-item menu, open stagger: 0ms, 90ms, 180ms out of 480ms
    final stagger = 90 / 480.0;
    final itemDuration = 0.52;

    // On open: last visual item first, on close: first visual item first
    final int staggerIndex =
        _isOpening ? (itemCount - 1 - visualIndex) : visualIndex;
    final openStart = staggerIndex * stagger;
    final openEnd = openStart + itemDuration;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        double itemT;
        if (t <= openStart) {
          itemT = 0.0;
        } else if (t >= openEnd) {
          itemT = 1.0;
        } else {
          itemT = (t - openStart) / (openEnd - openStart);
        }

        // Topmost item (visualIndex 0), last to appear on open, gets a subtle bounce
        final easedT = Curves.easeOut.transform(itemT.clamp(0.0, 1.0));
        final bounce = visualIndex == 0 && _isOpening && itemT > 0.98
            ? math.sin((itemT - 0.98) / 0.02 * math.pi) * 0.04
            : 0.0;
        // Opacity always clamped to [0,1]; translation allows overshoot for bounce
        final opacity = easedT.clamp(0.0, 1.0);
        final offsetY = 24 * (1 - easedT) - bounce * 24;
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, offsetY),
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _cascadeItem(
            0,
            _AddMenuRow(
              label: 'Attach file or image',
              onTap: widget.onPickFile,
            ),
          ),
          _cascadeItem(
            1,
            _AddMenuRow(
              label:
                  widget.isCreationMode ? 'Creation mode is on' : 'Creations',
              onTap: widget.isCreationMode
                  ? null
                  : () => setState(
                      () => _isCreationsExpanded = !_isCreationsExpanded),
              active: widget.isCreationMode,
              trailing: widget.isCreationMode
                  ? Icon(Icons.check_rounded,
                      color: nomad.textPrimary, size: 18)
                  : Icon(
                      _isCreationsExpanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      color: nomad.textSecondary,
                      size: 20,
                    ),
            ),
          ),
          if (_isCreationsExpanded && !widget.isCreationMode)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 2),
                  _AddMenuSubRow(
                    label: 'Playground',
                    onTap: () {
                      widget.onSelectCreationType('playground');
                    },
                  ),
                  _AddMenuSubRow(
                    label: 'Widget',
                    onTap: () {
                      widget.onSelectCreationType('widget');
                    },
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          if (!widget.isCreationMode)
            _cascadeItem(
              2,
              _AddMenuRow(
                label: widget.searchEnabled ? 'Web search · on' : 'Web search',
                onTap: widget.onToggleSearch,
                active: widget.searchEnabled,
                trailing: widget.searchEnabled
                    ? Icon(Icons.check_rounded,
                        color: nomad.textPrimary, size: 18)
                    : null,
              ),
            ),
          if (widget.isCreationMode)
            _cascadeItem(
              2,
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Text(
                  'Web search and voice are paused while you build a creation.',
                  style: textTheme.bodySmall?.copyWith(
                    color: nomad.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _AddMenuRow extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Widget? trailing;

  const _AddMenuRow({
    required this.label,
    this.onTap,
    this.active = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    return BouncyTap(
      onTap: onTap,
      scaleDown: 0.97,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: textTheme.displaySmall?.copyWith(
                fontSize: 20,
                color: nomad.textPrimary,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 4),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _AddMenuSubRow extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _AddMenuSubRow({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    return BouncyTap(
      onTap: onTap,
      scaleDown: 0.97,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          label,
          style: textTheme.displaySmall?.copyWith(
            fontSize: 20,
            color: nomad.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Cascade-animated dropdown for model switching. Same animation as
/// [_AddMenuPanel]: bottom item slides up first on open, top slides down
/// first on close, with a subtle bounce on the topmost item.
class _ModelPickerDropdown extends StatefulWidget {
  final List<HFModel> models;
  final bool isOpen;
  final VoidCallback? onCloseComplete;
  final void Function(HFModel model) onSelect;

  const _ModelPickerDropdown({
    required this.models,
    required this.isOpen,
    required this.onSelect,
    this.onCloseComplete,
  });

  @override
  State<_ModelPickerDropdown> createState() => _ModelPickerDropdownState();
}

class _ModelPickerDropdownState extends State<_ModelPickerDropdown>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isOpening = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _isOpening = widget.isOpen;
    if (widget.isOpen) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_ModelPickerDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isOpen && !widget.isOpen) {
      _isOpening = false;
      _controller.reverse().then((_) {
        widget.onCloseComplete?.call();
      });
    } else if (!oldWidget.isOpen && widget.isOpen) {
      _isOpening = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Same cascade logic as [_AddMenuPanel._cascadeItem], but items slide
  /// DOWN from above (the model picker expands downward from the header).
  Widget _cascadeItem(int visualIndex, Widget child) {
    final itemCount = widget.models.length;
    final stagger = 60 / 300.0;
    final itemDuration = 0.52;

    // visualIndex 0 = topmost (closest to header), itemCount-1 = bottommost
    // On open: bottom appears first (itemCount-1 → ... → 0)
    // On close: top disappears first (0 → ... → itemCount-1)
    final int staggerIndex =
        _isOpening ? (itemCount - 1 - visualIndex) : visualIndex;
    final openStart = staggerIndex * stagger;
    final openEnd = openStart + itemDuration;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        double itemT;
        if (t <= openStart) {
          itemT = 0.0;
        } else if (t >= openEnd) {
          itemT = 1.0;
        } else {
          itemT = (t - openStart) / (openEnd - openStart);
        }

        final easedT = Curves.easeOut.transform(itemT.clamp(0.0, 1.0));
        // Topmost item is last to appear on open — give it a subtle bounce
        final bounce = visualIndex == 0 && _isOpening && itemT > 0.98
            ? math.sin((itemT - 0.98) / 0.02 * math.pi) * 0.04
            : 0.0;
        final opacity = easedT.clamp(0.0, 1.0);
        // Slide DOWN: items start above their final position (negative Y)
        final offsetY = -24 * (1 - easedT) + bounce * 24;
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, offsetY),
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widget.models.asMap().entries.map((entry) {
          final index = entry.key;
          final model = entry.value;
          String modelSuffix = '';
          final mn = model.name.toLowerCase();
          if (mn.contains('nano')) {
            modelSuffix = ' Nano';
          } else if (mn.contains('lite')) {
            modelSuffix = ' Lite';
          } else if (mn.contains('steady')) {
            modelSuffix = ' Steady';
          } else if (mn.contains('smart')) {
            modelSuffix = ' Smart';
          } else if (mn.contains('pro')) {
            modelSuffix = ' Pro';
          } else if (mn.contains('creative')) {
            modelSuffix = ' Creative';
          }
          return _cascadeItem(
            index,
            BouncyTap(
              scaleDown: 0.97,
              onTap: () => widget.onSelect(model),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  modelSuffix,
                  style: textTheme.displaySmall?.copyWith(
                    fontSize: 20,
                    color: Theme.of(context)
                        .extension<NomadColorsExtension>()!
                        .textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Sticky tag that sits above the composer while creation mode is on.
/// The dismiss button reuses the "X" idiom (rotated plus glyph) so it
/// feels of-a-piece with the composer's add button.
class _CreationChip extends StatelessWidget {
  final VoidCallback onDismiss;
  final String creationType;
  const _CreationChip(
      {required this.onDismiss, this.creationType = 'playground'});

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final isWidget = creationType == 'widget';
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: nomad.textPrimary,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isWidget ? Icons.widgets_rounded : Icons.auto_awesome_rounded,
              size: 14,
              color: nomad.background,
            ),
            const SizedBox(width: 6),
            Text(
              isWidget ? 'Widget' : 'Creation',
              style: textTheme.labelLarge?.copyWith(
                color: nomad.background,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 8),
            BouncyTap(
              onTap: onDismiss,
              scaleDown: 0.85,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: nomad.background.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  // Reuse the rotated-plus = X idiom.
                  child: Transform.rotate(
                    angle: 0.785398, // 45° in radians
                    child: SvgPicture.asset(
                      'assets/images/plus.svg',
                      width: 14,
                      height: 14,
                      colorFilter: ColorFilter.mode(
                        nomad.background,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerIconButton extends StatelessWidget {
  final String tooltip;
  final IconData? icon;
  final String? svgAsset;
  final VoidCallback onTap;
  final bool isActive;

  const _ComposerIconButton({
    required this.tooltip,
    this.icon,
    this.svgAsset,
    required this.onTap,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return BouncyTap(
      tooltip: tooltip,
      onTap: onTap,
      scaleDown: 0.86,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: isActive
              ? nomad.textPrimary.withValues(alpha: 0.08)
              : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: svgAsset != null
              ? SvgPicture.asset(
                  svgAsset!,
                  width: 26,
                  height: 26,
                  colorFilter:
                      ColorFilter.mode(nomad.textPrimary, BlendMode.srcIn),
                )
              : Icon(
                  icon ?? Icons.circle,
                  size: 25,
                  color: nomad.textPrimary,
                ),
        ),
      ),
    );
  }
}

class _AnimatedPencilButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AnimatedPencilButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return BouncyTap(
      onTap: onTap,
      tooltip: AppLocalizations.of(context)!.newChat,
      scaleDown: 0.85,
      child: SizedBox.square(
        dimension: 48,
        child: Center(
            child: SvgPicture.asset(
          'assets/images/compose.svg',
          width: 24,
          height: 24,
          colorFilter: ColorFilter.mode(nomad.textPrimary, BlendMode.srcIn),
        )),
      ),
    );
  }
}

class _ThinkingProcessBlock extends StatefulWidget {
  final String content;
  final NomadColorsExtension nomad;
  final TextTheme textTheme;

  const _ThinkingProcessBlock({
    required this.content,
    required this.nomad,
    required this.textTheme,
  });

  @override
  State<_ThinkingProcessBlock> createState() => _ThinkingProcessBlockState();
}

class _ThinkingProcessBlockState extends State<_ThinkingProcessBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final preview = widget.content.length > 150
        ? '${widget.content.substring(0, 150)}...'
        : widget.content;

    return BouncyTap(
      onTap: () => setState(() => _expanded = !_expanded),
      scaleDown: 0.99,
      child: Opacity(
        opacity: _expanded ? 1.0 : 0.5,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: widget.nomad.textSecondary.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(NomadRadii.card),
            border: Border.all(
              color: widget.nomad.border.withValues(
                alpha: _expanded ? 0.5 : 0.25,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: widget.nomad.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Thinking process',
                    style: widget.textTheme.labelLarge?.copyWith(
                      color: widget.nomad.textSecondary,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: widget.nomad.textSecondary,
                  ),
                ],
              ),
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    widget.content,
                    style: widget.textTheme.bodySmall?.copyWith(
                      color: widget.nomad.textSecondary,
                      height: 1.55,
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: widget.textTheme.bodySmall?.copyWith(
                      color: widget.nomad.textSecondary,
                      height: 1.45,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Subtle pulsing text for loading states (e.g. "Loading model").
class _PulseText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const _PulseText({required this.text, this.style});

  @override
  State<_PulseText> createState() => _PulseTextState();
}

class _PulseTextState extends State<_PulseText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: 0.4 + 0.6 * _controller.value,
          child: child,
        );
      },
      child: Text(widget.text, style: widget.style),
    );
  }
}
