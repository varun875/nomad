import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/chat_session.dart';
import '../../core/constants/responsive.dart';
import '../../core/theme/nomad_theme.dart';
import '../../core/providers/model_provider.dart';
import '../../core/widgets/nomad_animations.dart';
import '../../core/widgets/nomad_widgets.dart';
import '../../l10n/app_localizations.dart';
import 'chat_screen.dart';

class ChatHistoryScreen extends ConsumerStatefulWidget {
  const ChatHistoryScreen({super.key, this.currentLocation});

  final String? currentLocation;

  @override
  ConsumerState<ChatHistoryScreen> createState() => _ChatHistoryScreenState();
}

class _ChatHistoryScreenState extends ConsumerState<ChatHistoryScreen> {
  final Map<String, GlobalKey> _conversationKeys = {};

  void _startNewChat() {
    ref.read(chatMessagesProvider.notifier).clear();
    context.go('/home');
  }

  void _selectConversation(ChatSession conv) {
    final chat = ref.read(chatMessagesProvider.notifier);
    if (chat.conversationId != conv.id) {
      if (conv.modelId != null) {
        ref.read(selectedModelIdProvider.notifier).select(conv.modelId);
      }
      chat.openConversation(conv);
    }
    context.go('/home');
  }

  void _showRenameDialog(BuildContext context, ChatSession conv) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final textController = TextEditingController(text: conv.title);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: nomad.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NomadRadii.dialog),
        ),
        title: Text(
          AppLocalizations.of(context)!.renameChat,
          style: textTheme.headlineMedium,
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: textTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context)!.chatName,
            hintStyle: textTheme.bodyLarge?.copyWith(
              color: nomad.textSecondary,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: BorderSide(color: nomad.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: BorderSide(color: nomad.textPrimary, width: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              HapticFeedback.lightImpact();
              Navigator.pop(ctx);
            },
            child: Text(
              AppLocalizations.of(context)!.cancel,
              style: textTheme.bodyMedium?.copyWith(color: nomad.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              HapticFeedback.lightImpact();
              final newTitle = textController.text.trim();
              if (newTitle.isNotEmpty) {
                final updatedConv = ChatSession(
                  id: conv.id,
                  title: newTitle,
                  messages: conv.messages,
                  updatedAt: conv.updatedAt,
                  modelId: conv.modelId,
                );
                ref
                    .read(conversationsProvider.notifier)
                    .updateConversation(updatedConv);
              }
              Navigator.pop(ctx);
            },
            child: Text(
              AppLocalizations.of(context)!.save,
              style: textTheme.bodyMedium?.copyWith(
                color: nomad.textPrimary,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmation(BuildContext context, ChatSession conv) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: nomad.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NomadRadii.dialog),
        ),
        title: Text(
          '${AppLocalizations.of(context)!.delete} "${conv.title}"?',
          style: textTheme.headlineMedium,
        ),
        actions: [
          TextButton(
            onPressed: () {
              HapticFeedback.lightImpact();
              Navigator.pop(ctx);
            },
            child: Text(
              AppLocalizations.of(context)!.cancel,
              style: textTheme.bodyMedium?.copyWith(color: nomad.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              HapticFeedback.lightImpact();
              if (ref.read(chatMessagesProvider.notifier).conversationId ==
                  conv.id) {
                ref.read(chatMessagesProvider.notifier).clear();
              }
              ref
                  .read(conversationsProvider.notifier)
                  .deleteConversation(conv.id);
              Navigator.pop(ctx);
            },
            child: Text(
              AppLocalizations.of(context)!.delete,
              style: textTheme.bodyMedium?.copyWith(
                color: Colors.red,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showContextMenu(
    BuildContext context,
    RenderBox renderBox,
    ChatSession conv,
  ) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final offset = renderBox.localToGlobal(Offset.zero);
    final itemSize = renderBox.size;

    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;

    if (isIOS) {
      showCupertinoModalPopup<String>(
        context: context,
        builder: (ctx) => CupertinoActionSheet(
          title: Text(
            conv.title,
            style: textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx, 'rename');
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.pencil,
                    color: nomad.textPrimary,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    AppLocalizations.of(context)!.rename,
                    style: textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(ctx, 'delete');
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.delete,
                    color: CupertinoColors.destructiveRed,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    AppLocalizations.of(context)!.delete,
                    style: textTheme.bodyLarge?.copyWith(
                      color: CupertinoColors.destructiveRed,
                    ),
                  ),
                ],
              ),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              AppLocalizations.of(context)!.cancel,
              style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w400),
            ),
          ),
        ),
      ).then((value) {
        if (!mounted) return;
        if (value == 'rename') {
          _showRenameDialog(this.context, conv);
        } else if (value == 'delete') {
          _showDeleteConfirmation(this.context, conv);
        }
      });
    } else {
      final position = RelativeRect.fromLTRB(
        offset.dx,
        offset.dy + itemSize.height + 10,
        offset.dx + itemSize.width,
        offset.dy + itemSize.height + 10,
      );
      showMenu<String>(
        context: context,
        position: position,
        color: nomad.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NomadRadii.menu),
        ),
        items: [
          PopupMenuItem<String>(
            value: 'rename',
            child: Row(
              children: [
                Icon(Icons.edit_outlined, color: nomad.textPrimary, size: 22),
                const SizedBox(width: 12),
                Text(
                  AppLocalizations.of(context)!.rename,
                  style: textTheme.bodyLarge,
                ),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'delete',
            child: Row(
              children: [
                const Icon(Icons.delete_outline, color: Colors.red, size: 22),
                const SizedBox(width: 12),
                Text(
                  AppLocalizations.of(context)!.delete,
                  style: textTheme.bodyLarge?.copyWith(color: Colors.red),
                ),
              ],
            ),
          ),
        ],
      ).then((value) {
        if (!mounted) return;
        if (value == 'rename') {
          _showRenameDialog(this.context, conv);
        } else if (value == 'delete') {
          _showDeleteConfirmation(this.context, conv);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final conversations = ref.watch(conversationsProvider);
    final activeConversationId = ref.watch(activeConversationIdProvider);
    final desktop = context.isDesktop;
    final loc = AppLocalizations.of(context)!;
    final location = widget.currentLocation ?? GoRouter.of(context).location;
    final destinations =
        <({String path, String label, String? svg, IconData? icon})>[
      if (desktop)
        (
          path: '/home',
          label: loc.chat,
          svg: null,
          icon: Icons.chat_bubble_outline_rounded,
        ),
      (path: '/code', label: 'Code', svg: null, icon: Icons.code_rounded),
      (
        path: '/creations',
        label: loc.creations,
        svg: 'assets/images/canvas.svg',
        icon: null,
      ),
      (
        path: '/you',
        label: 'You',
        svg: 'assets/images/relieved-02.svg',
        icon: null,
      ),
      (
        path: '/skills',
        label: 'Skills',
        svg: 'assets/images/book-open-text.svg',
        icon: null,
      ),
      (
        path: '/settings/models',
        label: loc.models,
        svg: 'assets/images/chip.svg',
        icon: null,
      ),
    ];
    final actions = destinations.map((destination) {
      final selected = location == destination.path ||
          location.startsWith('${destination.path}/');
      return _SidebarAction(
        key: ValueKey('navigation-${destination.path}'),
        svgAsset: destination.svg,
        icon: destination.icon,
        label: destination.label,
        selected: selected,
        desktop: desktop,
        onTap: () {
          if (selected) return;
          if (destination.path == '/home') {
            context.go('/home');
          } else {
            context.push(destination.path);
          }
        },
      );
    }).toList();

    return Scaffold(
      backgroundColor: nomad.background,
      body: SafeArea(
        child: CustomScrollView(
          scrollCacheExtent: const ScrollCacheExtent.pixels(150),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(
                      'Nomad',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.displaySmall?.copyWith(
                        fontSize: 20,
                        decoration: TextDecoration.none,
                      ),
                    )),
                    _SidebarHeaderButton(
                      svgAsset: 'assets/images/settings.svg',
                      tooltip: AppLocalizations.of(context)!.settings,
                      selected: location.startsWith('/settings') &&
                          !location.startsWith('/settings/models'),
                      onTap: () {
                        if (location != '/settings') context.push('/settings');
                      },
                    ),
                    const SizedBox(width: 4),
                    _SidebarHeaderButton(
                      svgAsset: 'assets/images/compose.svg',
                      tooltip: AppLocalizations.of(context)!.newChat,
                      onTap: _startNewChat,
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: desktop
                    ? Column(
                        key: const ValueKey('desktop-navigation'),
                        children: [
                          for (final action in actions)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: action,
                            ),
                        ],
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final columns = constraints.maxWidth >= 300 ? 3 : 2;
                          final scale =
                              MediaQuery.textScalerOf(context).scale(13) / 13;
                          return GridView.count(
                            key: const ValueKey('mobile-navigation'),
                            crossAxisCount: columns,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio:
                                (constraints.maxWidth - (columns - 1) * 8) /
                                    columns /
                                    (80 + 40 * scale),
                            shrinkWrap: true,
                            primary: false,
                            physics: const NeverScrollableScrollPhysics(),
                            children: actions,
                          );
                        },
                      ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: NomadSectionLabel(loc.chatHistory),
              ),
            ),
            if (conversations.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/images/sad_face.png',
                        width: 40,
                        height: 40,
                        color: nomad.textSecondary.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'No history; start chatting',
                        style: textTheme.labelLarge?.copyWith(
                          color: nomad.textSecondary,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final conv = conversations[index];
                    final isSelected = activeConversationId == conv.id;
                    final itemKey = _conversationKeys.putIfAbsent(
                      conv.id,
                      GlobalKey.new,
                    );
                    void showActions() {
                      HapticFeedback.heavyImpact();
                      final renderBox = itemKey.currentContext
                          ?.findRenderObject() as RenderBox?;
                      if (renderBox == null) return;
                      _showContextMenu(context, renderBox, conv);
                    }

                    return Container(
                      key: itemKey,
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? nomad.textPrimary.withValues(alpha: 0.06)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(NomadRadii.control),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: BouncyTap(
                              onTap: () => _selectConversation(conv),
                              onLongPress: showActions,
                              tooltip: conv.title,
                              selected: isSelected,
                              scaleDown: 0.98,
                              child: Container(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Text(
                                  conv.title,
                                  style: textTheme.bodyMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Chat actions',
                            onPressed: showActions,
                            icon: const Icon(
                              Icons.more_horiz_rounded,
                              size: 20,
                            ),
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                          ),
                        ],
                      ),
                    );
                  }, childCount: conversations.length),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SidebarHeaderButton extends StatelessWidget {
  final String svgAsset;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;

  const _SidebarHeaderButton({
    required this.svgAsset,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return BouncyTap(
      tooltip: tooltip,
      onTap: onTap,
      selected: selected,
      scaleDown: 0.95,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: selected
              ? nomad.accent.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(NomadRadii.control),
        ),
        child: Center(
          child: SvgPicture.asset(
            svgAsset,
            width: 22,
            height: 22,
            colorFilter: ColorFilter.mode(nomad.textPrimary, BlendMode.srcIn),
          ),
        ),
      ),
    );
  }
}

class _SidebarAction extends StatelessWidget {
  final String? svgAsset;
  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool desktop;

  const _SidebarAction({
    super.key,
    this.svgAsset,
    this.icon,
    required this.label,
    required this.onTap,
    required this.selected,
    required this.desktop,
  }) : assert(svgAsset != null || icon != null);

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final glyph = icon != null
        ? Icon(icon, size: 24, color: nomad.textPrimary)
        : SvgPicture.asset(
            svgAsset!,
            width: 24,
            height: 24,
            colorFilter: ColorFilter.mode(nomad.textPrimary, BlendMode.srcIn),
          );
    final title = Text(
      label,
      maxLines: desktop ? 1 : 2,
      textAlign: desktop ? TextAlign.start : TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: (desktop ? textTheme.bodyMedium : textTheme.bodySmall)?.copyWith(
        color: nomad.textPrimary,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    );
    return BouncyTap(
      onTap: onTap,
      tooltip: label,
      selected: selected,
      scaleDown: 0.97,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? nomad.accent.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(NomadRadii.control),
          border: Border.all(
            color: selected ? nomad.borderStrong : Colors.transparent,
          ),
        ),
        child: desktop
            ? Row(
                children: [
                  glyph,
                  const SizedBox(width: 12),
                  Expanded(child: title),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.circle, size: 6, color: nomad.textPrimary),
                  ],
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: nomad.surface,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: glyph,
                  ),
                  const SizedBox(height: 8),
                  title,
                ],
              ),
      ),
    );
  }
}
