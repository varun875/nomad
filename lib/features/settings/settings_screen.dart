import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_version.dart';
import '../../core/theme/nomad_theme.dart';
import '../../core/widgets/nomad_widgets.dart';
import '../../core/widgets/nomad_animations.dart';
import '../../core/services/inference_service.dart';
import '../../features/chat/chat_screen.dart';
import '../../features/creations/creations_screen.dart';
import '../../l10n/app_localizations.dart';

/// Settings — monochrome, borderless redesign.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _showTokenSpeed = false;
  bool _isAssistantEnabled = false;
  int? _threadOverride;

  @override
  void initState() {
    super.initState();
    _loadPreference();
  }

  Future<void> _loadPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _showTokenSpeed = prefs.getBool('showTokenSpeed') ?? false;
        _isAssistantEnabled = prefs.getBool('isAssistantEnabled') ?? false;
        _threadOverride = prefs.getInt(
          InferenceService.generationThreadsPreference,
        );
      });
    }
  }

  Future<void> _toggleTokenSpeed(bool value) async {
    HapticFeedback.selectionClick();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showTokenSpeed', value);
    if (mounted) setState(() => _showTokenSpeed = value);
  }

  Future<void> _toggleAssistant(bool value) async {
    HapticFeedback.selectionClick();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isAssistantEnabled', value);
    if (mounted) setState(() => _isAssistantEnabled = value);
    
    // In a real implementation, we would trigger platform-specific code here
    // for Android's ACTION_VOICE_ASSISTANT_SETTINGS or similar.
  }

  Future<void> _chooseDecodeThreads() async {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final selectedValue = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: nomad.surface,
        title: Text('Decode Threads', style: textTheme.headlineMedium),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in <int?>[null, 2, 4, 6, 8])
              RadioListTile<int>(
                value: option ?? 0,
                groupValue: _threadOverride ?? 0,
                title: Text(option == null ? 'Auto' : '$option threads'),
                onChanged: (value) => Navigator.pop(dialogContext, value),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (selectedValue == null) return;
    final selected = selectedValue == 0 ? null : selectedValue;
    if (selected == null && _threadOverride == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (selected == null) {
      await prefs.remove(InferenceService.generationThreadsPreference);
    } else {
      await prefs.setInt(
        InferenceService.generationThreadsPreference,
        selected,
      );
    }
    await InferenceService().unloadModel();
    if (mounted) {
      setState(() => _threadOverride = selected);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thread profile applied on next message')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final brightness = Theme.of(context).brightness;
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final loc = AppLocalizations.of(context)!;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            brightness == Brightness.dark ? Brightness.light : Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: nomad.background,
        body: Stack(
            children: [
              Positioned(
                left: 20,
                top: topPadding + 48,
                child: NomadBackButton(onTap: () => context.pop()),
              ),
              Positioned(
                left: 20,
                top: topPadding + 100,
                child: NomadTitle(title: loc.settings),
              ),
              Positioned.fill(
                top: topPadding + 150,
                left: 20,
                right: 20,
                child: ListView(
                  padding: EdgeInsets.only(bottom: bottomSafe + 24),
                  scrollCacheExtent: const ScrollCacheExtent.pixels(500),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    const _SectionLabel(label: 'General'),
                    const SizedBox(height: 10),
                    _StickerTile(
                      title: 'Token Speed',
                      subtitle: 'Show tok/s on chat and editor',
                      icon: Icons.speed_rounded,
                      trailing: CupertinoSwitch(
                        value: _showTokenSpeed,
                        activeTrackColor: nomad.textPrimary,
                        onChanged: _toggleTokenSpeed,
                      ),
                      onTap: () => _toggleTokenSpeed(!_showTokenSpeed),
                    ),
                    const SizedBox(height: 16),
                    _StickerTile(
                      title: 'Decode Threads',
                      subtitle: _threadOverride == null
                          ? 'Auto'
                          : '${_threadOverride!} threads · reloads model',
                      icon: Icons.tune_rounded,
                      showChevron: true,
                      onTap: _chooseDecodeThreads,
                    ),
                    const SizedBox(height: 16),
                    _StickerTile(
                      title: 'Digital Assistant',
                      subtitle: 'Use Nomad as your default assistant (Android)',
                      icon: Icons.assistant_rounded,
                      trailing: CupertinoSwitch(
                        value: _isAssistantEnabled,
                        activeTrackColor: nomad.textPrimary,
                        onChanged: _toggleAssistant,
                      ),
                      onTap: () => _toggleAssistant(!_isAssistantEnabled),
                    ),
                    const SizedBox(height: 28),
                    const _SectionLabel(label: 'Data'),
                    const SizedBox(height: 10),
                    _StickerTile(
                      title: loc.clearCache,
                      subtitle: loc.removeTemporaryFiles,
                      icon: Icons.delete_sweep_rounded,
                      destructive: true,
                      onTap: () => _confirmClearCache(context, textTheme),
                    ),
                    const SizedBox(height: 28),
                    const _SectionLabel(label: 'About'),
                    const SizedBox(height: 10),
                    _StickerTile(
                      title: loc.aboutNomad,
                      subtitle: '${loc.version} ${AppVersion.version}',
                      icon: Icons.info_rounded,
                      onTap: () => context.push('/settings/about'),
                      showChevron: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
      ),
    );
}

  void _confirmClearCache(BuildContext context, TextTheme textTheme) {
    final screenContext = context;
    final nomad = Theme.of(screenContext).extension<NomadColorsExtension>()!;
    final loc = AppLocalizations.of(screenContext)!;
    showDialog(
      context: screenContext,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: nomad.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NomadRadii.dialog)),
        title: Text(loc.clearCacheQuestion, style: textTheme.headlineMedium),
        content: Text(loc.clearCacheMessage, style: textTheme.bodySmall),
        actions: [
          TextButton(
            onPressed: () {
              HapticFeedback.lightImpact();
              Navigator.pop(dialogContext);
            },
            child: Text(loc.cancel,
                style:
                    textTheme.bodyMedium?.copyWith(color: nomad.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              HapticFeedback.lightImpact();
              Navigator.pop(dialogContext);
              final prefs = await SharedPreferences.getInstance();
              for (final key in [
                'onboarded',
                'selectedModelId',
                'language'
              ]) {
                await prefs.remove(key);
              }
              await Hive.box('chats').clear();
              await Hive.box('creations').clear();
              await Hive.box('settings').clear();
              // Reset in-memory providers so ghost history doesn't persist until restart.
              ref.invalidate(conversationsProvider);
              ref.invalidate(creationsProvider);
              ref.invalidate(chatMessagesProvider);
              if (screenContext.mounted) {
                ScaffoldMessenger.of(screenContext).showSnackBar(
                  SnackBar(
                    content: Text(loc.cacheCleared,
                        style: textTheme.bodySmall),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NomadRadii.snackBar)),
                    margin: const EdgeInsets.all(20),
                  ),
                );
              }
            },
            child: Text(loc.confirm,
                style: textTheme.bodyMedium
                    ?.copyWith(color: Colors.red, fontWeight: FontWeight.w400)),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Text(
        label.toUpperCase(),
        style: textTheme.labelLarge?.copyWith(
          color: nomad.textSecondary,
          letterSpacing: 1.4,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// Monochrome settings tile: a simple rounded icon container on the left and
/// a soft drop shadow under the whole card so it pops off the page.
class _StickerTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool destructive;
  final bool showChevron;

  const _StickerTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.onTap,
    this.trailing,
    this.destructive = false,
    this.showChevron = false,
  });

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;

    return BouncyTap(
      onTap: onTap,
      scaleDown: 0.97,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
        decoration: BoxDecoration(
          color: nomad.surface,
          borderRadius: BorderRadius.circular(NomadRadii.card),
        ),
        child: Row(
          children: [
            _StickerChip(icon: icon),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: textTheme.bodyLarge?.copyWith(
                      color: nomad.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: textTheme.bodySmall),
                ],
              ),
            ),
            if (trailing != null) trailing!,
            if (showChevron)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: nomad.textSecondary.withValues(alpha: 0.55),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Monochrome rounded icon container.
class _StickerChip extends StatelessWidget {
  final IconData icon;

  const _StickerChip({required this.icon});

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: nomad.textPrimary.withValues(alpha: 0.05),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Icon(
          icon,
          size: 20,
          color: nomad.textPrimary,
        ),
      ),
    );
  }
}
