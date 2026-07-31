import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/performance_service.dart';
import '../theme/nomad_theme.dart';
import 'nomad_animations.dart';

enum BackdropState { idle, loading, streaming }

class NomadSectionLabel extends StatelessWidget {
  const NomadSectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: nomad.textSecondary,
            letterSpacing: 0.8,
          ),
    );
  }
}

class NomadStickerChip extends StatelessWidget {
  const NomadStickerChip({super.key, required this.icon, this.size = 44});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: nomad.surfaceSecondary,
        shape: BoxShape.circle,
        border: Border.all(color: nomad.border),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.48, color: nomad.textPrimary),
    );
  }
}

/// A living "aurora" backdrop: a handful of soft, slowly drifting colour blobs
/// over the page background. It breathes gently while idle and warms to a rosy
/// palette while a model is loading, transitioning smoothly between the two.
class NomadBackdrop extends StatefulWidget {
  final bool compact;
  final BackdropState state;

  const NomadBackdrop({
    super.key,
    this.compact = false,
    this.state = BackdropState.idle,
  });

  @override
  State<NomadBackdrop> createState() => _NomadBackdropState();
}

class _NomadBackdropState extends State<NomadBackdrop>
    with TickerProviderStateMixin {
  late final AnimationController _drift;
  late final AnimationController _loadCtrl;
  late final Animation<double> _loadAnim;

  @override
  void initState() {
    super.initState();
    _drift = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 28),
    );
    // The drifting aurora repaints the entire screen every frame. On low-end
    // devices that continuous cost is a primary cause of dropped frames,
    // "missing" animations, and battery drain, so we keep the backdrop static
    // there and only animate it on capable hardware.
    if (!PerformanceService.instance.isConstrained) {
      _drift.repeat();
    }
    _loadCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
      value: widget.state == BackdropState.loading ? 1.0 : 0.0,
    );
    _loadAnim = CurvedAnimation(parent: _loadCtrl, curve: Curves.easeInOut);
  }

  @override
  void didUpdateWidget(NomadBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state != oldWidget.state) {
      if (widget.state == BackdropState.loading) {
        _loadCtrl.animateTo(1.0, duration: const Duration(milliseconds: 1100));
      } else if (widget.state == BackdropState.streaming) {
        // Streaming uses a gentler shift — go to 0.45 for a subtler warm tint
        _loadCtrl.animateTo(0.45, duration: const Duration(milliseconds: 1800));
      } else {
        _loadCtrl.animateTo(0.0, duration: const Duration(milliseconds: 1400));
      }
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    _loadCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = Theme.of(context).extension<NomadColorsExtension>()!.background;

    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_drift, _loadAnim]),
          builder: (context, _) {
            return CustomPaint(
              painter: _AuroraPainter(
                t: _drift.value,
                loadT: _loadAnim.value,
                isDark: isDark,
                bg: bg,
              ),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}

class _Blob {
  final double baseX; // fractional 0..1
  final double baseY;
  final double ampX;
  final double ampY;
  final double phase;
  final double radius; // fraction of the shortest side
  final int colorIndex;
  const _Blob(this.baseX, this.baseY, this.ampX, this.ampY, this.phase,
      this.radius, this.colorIndex);
}

class _AuroraPainter extends CustomPainter {
  final double t;
  final double loadT;
  final bool isDark;
  final Color bg;

  _AuroraPainter({
    required this.t,
    required this.loadT,
    required this.isDark,
    required this.bg,
  });

  // Idle palette — cool mint / teal / aqua.
  static const _idleLight = [
    Color(0xFF7DFFCD),
    Color(0xFF63E6C4),
    Color(0xFF9BF5DC),
  ];
  static const _idleDark = [
    Color(0xFF5CFFB5),
    Color(0xFF36D9A8),
    Color(0xFF49C8E0),
  ];
  // Loading palette — warm rose.
  static const _loadLight = [
    Color(0xFFE8A0BF),
    Color(0xFFEFBAD5),
    Color(0xFFF3C9B0),
  ];
  static const _loadDark = [
    Color(0xFFD48FAB),
    Color(0xFFC87DAA),
    Color(0xFFB98FD4),
  ];

  static const List<_Blob> _blobs = [
    _Blob(0.18, 0.82, 0.10, 0.06, 0.0, 0.85, 0),
    _Blob(0.82, 0.88, 0.12, 0.05, 1.9, 0.95, 1),
    _Blob(0.70, 0.30, 0.10, 0.08, 3.6, 0.70, 2),
    _Blob(0.25, 0.32, 0.09, 0.07, 5.1, 0.62, 1),
  ];

  Color _colorFor(int index) {
    final idle = isDark ? _idleDark[index] : _idleLight[index];
    final load = isDark ? _loadDark[index] : _loadLight[index];
    return Color.lerp(idle, load, loadT)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = bg);

    final shortest = size.shortestSide;
    final tau = 2 * math.pi;
    // Slightly livelier motion while loading.
    final speed = 1.0 + loadT * 0.4;
    // Idle blobs sit a touch stronger on dark backgrounds.
    final baseAlpha = (isDark ? 0.22 : 0.20) + loadT * 0.04;

    for (final b in _blobs) {
      final angle = t * tau * speed + b.phase;
      final dx = (b.baseX + b.ampX * math.sin(angle)) * size.width;
      final dy = (b.baseY + b.ampY * math.cos(angle * 0.9)) * size.height;
      final r = b.radius * shortest * (1.0 + 0.06 * math.sin(angle * 0.7));
      final color = _colorFor(b.colorIndex);

      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: baseAlpha),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: Offset(dx, dy), radius: r));
      canvas.drawCircle(Offset(dx, dy), r, paint);
    }

    // A soft veil from the centre keeps the middle of the screen calm and
    // text legible, while colour pools toward the edges.
    final veil = Paint()
      ..shader = RadialGradient(
        colors: [
          bg.withValues(alpha: isDark ? 0.34 : 0.30),
          bg.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.75],
      ).createShader(
        Rect.fromCircle(
          center: Offset(size.width * 0.5, size.height * 0.42),
          radius: shortest * 0.9,
        ),
      );
    canvas.drawRect(rect, veil);
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      t != old.t || loadT != old.loadT || isDark != old.isDark || bg != old.bg;
}

// ============================================================================
// NomadDottedBackground — soft low-opacity dot pattern. Cheap (single
// CustomPainter, no animation). Use as a background layer to give any
// page that playful sticker-on-paper feel.
// ============================================================================
class NomadDottedBackground extends StatelessWidget {
  final Widget child;
  final double spacing;
  final double radius;
  final double opacity;

  const NomadDottedBackground({
    super.key,
    required this.child,
    this.spacing = 22.0,
    this.radius = 1.0,
    this.opacity = 0.08,
  });

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _NomadDotPatternPainter(
                color: nomad.textPrimary,
                spacing: spacing,
                radius: radius,
                opacity: opacity,
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _NomadDotPatternPainter extends CustomPainter {
  final Color color;
  final double spacing;
  final double radius;
  final double opacity;

  _NomadDotPatternPainter({
    required this.color,
    required this.spacing,
    required this.radius,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: opacity);
    for (double y = spacing / 2; y < size.height; y += spacing) {
      for (double x = spacing / 2; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _NomadDotPatternPainter old) =>
      old.color != color ||
      old.spacing != spacing ||
      old.radius != radius ||
      old.opacity != opacity;
}

class NomadBackButton extends StatelessWidget {
  final VoidCallback onTap;
  final String label;

  const NomadBackButton({super.key, required this.onTap, this.label = 'Back'});

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;

    return BouncyTap(
      onTap: onTap,
      scaleDown: 0.92,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SvgPicture.asset(
              'assets/images/back_icon.svg',
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(
                nomad.textSecondary,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 13),
            Text(
              label,
              style: textTheme.bodyMedium?.copyWith(
                color: nomad.textSecondary,
                height: 1.22,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NomadTitle extends StatelessWidget {
  final String title;
  final String? subtitle;

  const NomadTitle({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: textTheme.displaySmall),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle!, style: textTheme.bodySmall),
        ],
      ],
    );
  }
}

class NomadEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const NomadEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: nomad.textPrimary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Icon(
              icon,
              size: 32,
              color: nomad.textSecondary.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: textTheme.bodyLarge?.copyWith(
              color: nomad.textSecondary.withValues(alpha: 0.8),
              fontWeight: FontWeight.w400,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              style: textTheme.bodySmall?.copyWith(
                color: nomad.textSecondary.withValues(alpha: 0.5),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

class NomadThinkingIndicator extends StatefulWidget {
  const NomadThinkingIndicator({super.key});

  @override
  State<NomadThinkingIndicator> createState() => _NomadThinkingIndicatorState();
}

class _NomadThinkingIndicatorState extends State<NomadThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _phase(int i) {
    final raw = (_controller.value + i * 0.2) % 1.0;
    return raw < 0.5 ? raw * 2.0 : 2.0 - raw * 2.0;
  }

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (index) {
              final a = _phase(index);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: nomad.textSecondary.withValues(alpha: 0.3 + 0.7 * a),
                  shape: BoxShape.circle,
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

class NomadSendButton extends StatelessWidget {
  final VoidCallback? onTap;
  final VoidCallback? onStop;
  final bool isEnabled;
  final bool isStreaming;

  const NomadSendButton({
    super.key,
    this.onTap,
    this.onStop,
    required this.isEnabled,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;

    if (isStreaming) {
      return BouncyTap(
        onTap: onStop,
        scaleDown: 0.85,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: nomad.textPrimary,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.stop_rounded, color: nomad.background, size: 20),
        ),
      );
    }

    return BouncyTap(
      onTap: isEnabled ? onTap : null,
      scaleDown: 0.85,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: isEnabled ? nomad.textPrimary : nomad.textTertiary,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Image.asset(
            'assets/images/arrow.png',
            width: 18,
            height: 18,
            color: nomad.background,
          ),
        ),
      ),
    );
  }
}
