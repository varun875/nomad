import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/nomad_theme.dart';
import '../../core/widgets/nomad_widgets.dart';
import '../../core/widgets/nomad_animations.dart';
import '../../core/constants/responsive.dart';
import 'licenses.dart';

class LicenseScreen extends StatelessWidget {
  final String id;
  const LicenseScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final brightness = Theme.of(context).brightness;
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final isDesktop = context.isDesktop;
    final topPad = isDesktop ? 20.0 : 0.0;

    final entry = NomadLicenses.byId(id);

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
              top: topPadding + 48 + topPad,
              child: NomadBackButton(onTap: () => context.pop()),
            ),
            Positioned(
              left: 20,
              right: 20,
              top: topPadding + 100 + topPad,
              child: BouncyFadeSlide(
                delay: NomadDurations.staggerStep,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: NomadTitle(title: entry?.name ?? 'License'),
                    ),
                    if (entry != null)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: nomad.textPrimary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(NomadRadii.card),
                        ),
                        child: Text(
                          entry.type,
                          style: textTheme.labelLarge?.copyWith(
                            color: nomad.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              left: 20,
              right: 20,
              top: topPadding + 150 + topPad,
              bottom: bottomSafe + 24,
              child: BouncyFadeSlide(
                delay: NomadDurations.staggerStep * 2,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  decoration: BoxDecoration(
                    color: nomad.surface,
                    borderRadius: BorderRadius.circular(NomadRadii.card),
                    border: Border.all(color: nomad.border, width: 1),
                  ),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: SelectableText(
                      (entry?.text ?? 'Unknown license.').trim(),
                      style: GoogleFonts.firaCode(
                        fontSize: 12.5,
                        height: 1.55,
                        color: nomad.textPrimary,
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
