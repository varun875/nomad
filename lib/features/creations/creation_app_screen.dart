import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/nomad_theme.dart';
import '../../l10n/app_localizations.dart';
import 'creation_preview.dart';
import 'creations_screen.dart';

class CreationAppScreen extends ConsumerWidget {
  final String creationId;
  const CreationAppScreen({super.key, required this.creationId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final brightness = Theme.of(context).brightness;
    final loaded = ref.watch(creationsLoadedProvider);
    final creations = ref.watch(creationsProvider);
    final l10n = AppLocalizations.of(context)!;

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
            Positioned.fill(
              child: loaded.when(
                skipLoadingOnRefresh: false,
                loading: () => Center(
                  child: CircularProgressIndicator(color: nomad.textPrimary),
                ),
                error: (error, stack) => CreationPreviewError(
                  message: 'Could not load creation. Please try again.',
                  onRetry: () => ref.invalidate(creationsProvider),
                ),
                data: (_) {
                  Creation? creation;
                  for (final item in creations) {
                    if (item.id == creationId) {
                      creation = item;
                      break;
                    }
                  }
                  if (creation == null) {
                    return CreationPreviewError(message: l10n.creationNotFound);
                  }
                  return SafeArea(
                    bottom: false,
                    child: CreationPreview(
                      key: ValueKey((creation.id, creation.html)),
                      html: creation.html,
                    ),
                  );
                },
              ),
            ),

            // Keep exit available even while storage or the webview is loading.
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              right: 12,
              child: IconButton(
                tooltip: l10n.goBack,
                style: IconButton.styleFrom(
                  backgroundColor: nomad.surface,
                  foregroundColor: nomad.textPrimary,
                ),
                onPressed: () {
                  HapticFeedback.lightImpact();
                  Navigator.of(context).maybePop();
                },
                icon: const Icon(Icons.close, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
