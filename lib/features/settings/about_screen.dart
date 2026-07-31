import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants/app_version.dart';
import '../../core/theme/nomad_theme.dart';
import '../../core/widgets/nomad_widgets.dart';
import '../../core/widgets/nomad_animations.dart';
import '../../l10n/app_localizations.dart';
import 'licenses.dart';

/// About — playful sticker-paper redesign.
///
/// Dotted background, large app icon sticker, sticker-style feature
/// chips, and licenses laid out as soft cards. No bottom cutoff.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final brightness = Theme.of(context).brightness;
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomSafe = MediaQuery.of(context).padding.bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
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
              child: const NomadTitle(title: 'About'),
            ),
            Positioned.fill(
              left: 20,
              right: 20,
              top: topPadding + 150,
              child: ListView(
                padding: EdgeInsets.only(bottom: bottomSafe + 24),
                    scrollCacheExtent: const ScrollCacheExtent.pixels(500),
                    physics: const BouncingScrollPhysics(),
                    children: [
                      // Hero — app icon + version.
                      BouncyFadeSlide(
                        delay: NomadDurations.staggerStep * 0,
                        child: Center(
                          child: Column(
                            children: [
                              const _AppIconSticker(),
                              const SizedBox(height: 22),
                              Text(
                                'Nomad',
                                style: textTheme.displaySmall?.copyWith(
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${AppLocalizations.of(context)!.version} ${AppVersion.version}',
                                style: textTheme.bodyMedium?.copyWith(
                                  color: nomad.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12),
                                child: Text(
                                  AppLocalizations.of(context)!.yourPrivateAI,
                                  textAlign: TextAlign.center,
                                  style: textTheme.bodyLarge?.copyWith(
                                    color: nomad.textSecondary,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 32),

                      // Description card.
                      BouncyFadeSlide(
                        delay: NomadDurations.staggerStep * 1,
                        child: _AboutCard(
                          children: [
                            Text(
                              'About Nomad',
                              style: textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Nomad is your private AI assistant that runs entirely on your device. '
                              'No data is sent to the cloud, ensuring complete privacy and security. '
                              'Powered by state-of-the-art open-source models, Nomad brings '
                              'intelligent conversation to your fingertips while keeping '
                              'your data local and secure.',
                              style: textTheme.bodyMedium?.copyWith(
                                color: nomad.textSecondary,
                                height: 1.6,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 22),

                      // Features — sticker rows.
                      const _SectionLabel(label: 'Key Features'),
                      const SizedBox(height: 12),
                      const _FeatureSticker(
                        icon: Icons.security,
                        title: '100% Private',
                        description:
                            'All processing happens on your device',
                      ),
                      const SizedBox(height: 10),
                      const _FeatureSticker(
                        icon: Icons.offline_bolt,
                        title: 'Works Offline',
                        description: 'No internet connection required',
                      ),
                      const SizedBox(height: 10),
                      const _FeatureSticker(
                        icon: Icons.memory,
                        title: 'Local Models',
                        description: 'Powered by open-source AI models',
                      ),
                      const SizedBox(height: 10),
                      const _FeatureSticker(
                        icon: Icons.devices,
                        title: 'Cross-Platform',
                        description:
                            'Available on mobile, tablet, and desktop',
                      ),

                      const SizedBox(height: 30),

                      // Licenses.
                      const _SectionLabel(label: 'Licenses'),
                      const SizedBox(height: 12),
                      for (int i = 0; i < NomadLicenses.all.length; i++) ...[
                        if (i > 0) const SizedBox(height: 10),
                        _LicenseTile(
                          name: NomadLicenses.all[i].name,
                          type: NomadLicenses.all[i].type,
                          onTap: () => context.push(
                            '/settings/about/license/${NomadLicenses.all[i].id}',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
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

class _AppIconSticker extends StatelessWidget {
  const _AppIconSticker();

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return Container(
      width: 112,
      height: 112,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: nomad.surface,
        shape: BoxShape.circle,
      ),
      child: ClipOval(
        child: Image.asset('assets/icon/app_icon.png', fit: BoxFit.cover),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  final List<Widget> children;
  const _AboutCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: nomad.surface,
        borderRadius: BorderRadius.circular(NomadRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _FeatureSticker extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureSticker({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
      decoration: BoxDecoration(
        color: nomad.surface,
        borderRadius: BorderRadius.circular(NomadRadii.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
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
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LicenseTile extends StatelessWidget {
  final String name;
  final String type;
  final VoidCallback onTap;

  const _LicenseTile({
    required this.name,
    required this.type,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;

    return BouncyTap(
      onTap: onTap,
      scaleDown: 0.97,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
        decoration: BoxDecoration(
          color: nomad.surface,
          borderRadius: BorderRadius.circular(NomadRadii.card),
        ),
        child: Row(
          children: [
            const _StickerChip(icon: Icons.description_rounded),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(type, style: textTheme.bodySmall),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20,
                color: nomad.textSecondary.withValues(alpha: 0.55)),
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
        child: Icon(icon, size: 20, color: nomad.textPrimary),
      ),
    );
  }
}
