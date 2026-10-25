import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/services/memory_service.dart';
import '../../core/services/performance_service.dart';
import '../../core/theme/nomad_theme.dart';
import '../../core/widgets/nomad_widgets.dart';
import '../../core/widgets/nomad_animations.dart';

final youMemoryServiceProvider =
    Provider<MemoryService>((ref) => MemoryService());
final youLowEndProvider =
    Provider<bool>((ref) => PerformanceService.instance.isLowEnd);

/// Memories remain browsable without waiting for, or running, the orbit.
class YouScreen extends ConsumerStatefulWidget {
  const YouScreen({super.key});

  @override
  ConsumerState<YouScreen> createState() => _YouScreenState();
}

class _YouScreenState extends ConsumerState<YouScreen> {
  late final _memoryService = ref.read(youMemoryServiceProvider);
  List<Memory> _memories = [];
  bool _loading = true;
  bool _loadFailed = false;
  bool _preferList = false;

  void _refreshMemories() {
    if (!mounted) return;
    setState(() => _memories = _memoryService.getAllMemories());
  }

  @override
  void initState() {
    super.initState();
    _loadMemories();
  }

  Future<void> _loadMemories() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      // Startup opens this encrypted box after the first frame. Await it here
      // too, rather than retaining the empty snapshot from before it opened.
      await _memoryService.init();
      if (!mounted) return;
      setState(() {
        _memories = _memoryService.getAllMemories();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final textTheme = Theme.of(context).textTheme;
    final lowEnd = ref.watch(youLowEndProvider);
    final media = MediaQuery.of(context);

    Widget? status;
    if (_loading) {
      status = const Center(
        child: CircularProgressIndicator(semanticsLabel: 'Loading memories'),
      );
    } else if (_loadFailed) {
      status = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            liveRegion: true,
            child: const Text(
              'Could not load memories. Please try again.',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _loadMemories,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              visualDensity: VisualDensity.standard,
            ),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry loading memories'),
          ),
        ],
      );
    } else if (_memories.isEmpty) {
      status = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bubble_chart_rounded,
              size: 48, color: nomad.textSecondary.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(
            'Nothing remembered yet',
            textAlign: TextAlign.center,
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Nomad saves facts and preferences here as you chat, or add one yourself.',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: nomad.textSecondary),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: nomad.background,
      // Only the add dialog has a text field; it handles its own keyboard inset.
      resizeToAvoidBottomInset: false,
      body: NomadPageReveal(
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(builder: (context, constraints) {
            final canOrbit = !lowEnd &&
                !media.disableAnimations &&
                !media.accessibleNavigation &&
                media.textScaler.scale(24) <= 36 &&
                constraints.maxWidth >= 760 &&
                constraints.maxHeight >= 760;
            final showList = !canOrbit || _preferList;
            final header = Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      NomadBackButton(onTap: () {
                        if (context.canPop()) {
                          context.pop();
                        } else {
                          context.go('/home');
                        }
                      }),
                      const Spacer(),
                      if (canOrbit && _memories.isNotEmpty)
                        BouncyTap(
                          onTap: () => setState(() => _preferList = !showList),
                          tooltip: showList
                              ? 'Show memory orbit'
                              : 'Show memory list',
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 48),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            decoration: BoxDecoration(
                              color: nomad.surface,
                              borderRadius:
                                  BorderRadius.circular(NomadRadii.control),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(showList
                                    ? Icons.bubble_chart_rounded
                                    : Icons.list_rounded),
                                const SizedBox(width: 8),
                                Text(showList ? 'Orbit' : 'List'),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  NomadTitle(
                    title: 'You',
                    subtitle: _loading || _loadFailed || _memories.isEmpty
                        ? null
                        : '${_memories.length} ${_memories.length == 1 ? 'memory' : 'memories'}',
                  ),
                ],
              ),
            );

            if (!showList && status == null) {
              return Column(
                children: [
                  header,
                  Expanded(
                    child: _OrbitUI(
                      memories: _memories,
                      onOpen: _showMemoryDetail,
                    ),
                  ),
                ],
              );
            }

            return CustomScrollView(
              key: const PageStorageKey('memory-list'),
              slivers: [
                SliverToBoxAdapter(child: header),
                if (status != null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Center(child: status),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    sliver: SliverList.builder(
                      itemCount: _memories.length,
                      itemBuilder: (context, index) {
                        final memory = _memories[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: BouncyTap(
                            key: ValueKey('memory-${memory.id}'),
                            onTap: () => _showMemoryDetail(memory),
                            semanticLabel:
                                'View ${memory.category} memory: ${memory.content}',
                            scaleDown: 0.98,
                            borderRadius:
                                BorderRadius.circular(NomadRadii.card),
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 72),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: nomad.surface,
                                borderRadius:
                                    BorderRadius.circular(NomadRadii.card),
                              ),
                              child: Row(
                                children: [
                                  NomadStickerChip(
                                      icon: _getCategoryIcon(memory.category)),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(memory.category.toUpperCase(),
                                            style: textTheme.labelSmall
                                                ?.copyWith(
                                                    color:
                                                        nomad.textSecondary)),
                                        const SizedBox(height: 4),
                                        Text(
                                          memory.content,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: textTheme.bodyMedium,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(Icons.chevron_right_rounded,
                                      color: nomad.textSecondary),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            );
          }),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Center(
            heightFactor: 1,
            child: BouncyTap(
              onTap: _loading || _loadFailed ? null : _showAddMemoryDialog,
              tooltip: 'Add memory',
              borderRadius: BorderRadius.circular(NomadRadii.card),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: nomad.surface,
                  borderRadius: BorderRadius.circular(NomadRadii.card),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const NomadStickerChip(icon: Icons.add_rounded),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        'Add Memory',
                        style: textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showAddMemoryDialog() {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    var content = '';
    var saving = false;
    String? error;

    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: nomad.surface,
          scrollable: true,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(NomadRadii.dialog)),
          title: const Text('New Memory'),
          content: TextField(
            onChanged: (value) => content = value,
            enabled: !saving,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Memory',
              hintText: 'What should Nomad remember?',
              errorText: error,
              errorMaxLines: 3,
            ),
            maxLines: 3,
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                visualDensity: VisualDensity.standard,
              ),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: saving
                  ? null
                  : () async {
                      final text = content.trim();
                      if (text.isEmpty) {
                        setDialogState(() => error = 'Enter a memory to save.');
                        return;
                      }
                      setDialogState(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        await _memoryService.saveMemory(text);
                        _refreshMemories();
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext);
                        }
                      } catch (_) {
                        if (!dialogContext.mounted) return;
                        setDialogState(() {
                          saving = false;
                          error =
                              'Could not save this memory. Please try again.';
                        });
                      }
                    },
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                visualDensity: VisualDensity.standard,
              ),
              child: Text(saving ? 'Saving...' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showMemoryDetail(Memory memory) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    var deleting = false;
    String? error;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: nomad.surface,
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(NomadRadii.sheet)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    NomadStickerChip(icon: _getCategoryIcon(memory.category)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        memory.category.toUpperCase(),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: nomad.textSecondary,
                              letterSpacing: 1.0,
                            ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Delete memory',
                      constraints:
                          const BoxConstraints(minWidth: 48, minHeight: 48),
                      visualDensity: VisualDensity.standard,
                      style: IconButton.styleFrom(
                        backgroundColor:
                            nomad.accentWarm.withValues(alpha: 0.18),
                        foregroundColor: nomad.textPrimary,
                      ),
                      onPressed: deleting
                          ? null
                          : () async {
                              setSheetState(() {
                                deleting = true;
                                error = null;
                              });
                              try {
                                await _memoryService.deleteMemory(memory.id);
                                _refreshMemories();
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                              } catch (_) {
                                if (!sheetContext.mounted) return;
                                setSheetState(() {
                                  deleting = false;
                                  error =
                                      'Could not delete this memory. Please try again.';
                                });
                              }
                            },
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                    IconButton(
                      tooltip: 'Close memory',
                      constraints:
                          const BoxConstraints(minWidth: 48, minHeight: 48),
                      visualDensity: VisualDensity.standard,
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      memory.content,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            height: 1.6,
                            fontSize: 17,
                          ),
                    ),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(error!)),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _getCategoryIcon(String category) {
  switch (category) {
    case 'preference':
      return Icons.favorite_rounded;
    case 'fact':
      return Icons.lightbulb_rounded;
    case 'biography':
      return Icons.history_edu_rounded;
    default:
      return Icons.bubble_chart_rounded;
  }
}

class _OrbitUI extends StatefulWidget {
  final List<Memory> memories;
  final ValueChanged<Memory> onOpen;

  const _OrbitUI({
    required this.memories,
    required this.onOpen,
  });

  @override
  State<_OrbitUI> createState() => _OrbitUIState();
}

class _OrbitUIState extends State<_OrbitUI>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildScene(BuildContext context, double progress, double radiusStep) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    return Stack(
      alignment: Alignment.center,
      children: [
        // Decorative connections and rings must not intercept memory taps.
        IgnorePointer(
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Neural-style connection lines
              CustomPaint(
                size: Size.infinite,
                painter: _NeuralConnectionPainter(
                  memories: widget.memories,
                  progress: progress,
                  nomad: nomad,
                  radiusStep: radiusStep,
                ),
              ),

              // Orbit Rings (Subtle)
              for (var i = 1; i <= 3; i++)
                Container(
                  width: i * radiusStep * 2,
                  height: i * radiusStep * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: nomad.textPrimary.withValues(alpha: 0.05),
                      width: 1,
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Central "You" node with pulsing aura.
        _CentralNode(nomad: nomad),

        // Orbiting Memories
        for (var i = 0; i < widget.memories.length; i++)
          _OrbitingNode(
            memory: widget.memories[i],
            index: i,
            total: widget.memories.length,
            progress: progress,
            nomad: nomad,
            radiusStep: radiusStep,
            onTap: () => widget.onOpen(widget.memories[i]),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Leave room for the 52px targets, their 5px float, and focus outlines.
        final radiusStep =
            math.min(110.0, (constraints.biggest.shortestSide / 2 - 36) / 3);
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) =>
              _buildScene(context, _controller.value, radiusStep),
        );
      },
    );
  }
}

class _CentralNode extends StatefulWidget {
  final NomadColorsExtension nomad;
  const _CentralNode({required this.nomad});

  @override
  State<_CentralNode> createState() => _CentralNodeState();
}

class _CentralNodeState extends State<_CentralNode>
    with SingleTickerProviderStateMixin {
  late final _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Widget _node(double pulse) {
    return Container(
      width: 100 + (pulse * 20),
      height: 100 + (pulse * 20),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.nomad.textPrimary.withValues(alpha: 0.05),
      ),
      child: Center(
        child: Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.nomad.surface,
          ),
          child: Icon(Icons.person_rounded,
              color: widget.nomad.textPrimary, size: 36),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) => _node(_pulseController.value),
    );
  }
}

class _NeuralConnectionPainter extends CustomPainter {
  final List<Memory> memories;
  final double progress;
  final NomadColorsExtension nomad;
  final double radiusStep;

  _NeuralConnectionPainter({
    required this.memories,
    required this.progress,
    required this.nomad,
    required this.radiusStep,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = nomad.textPrimary.withValues(alpha: 0.08)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    for (var i = 0; i < memories.length; i++) {
      final orbitIndex = (i % 3) + 1;
      final radius = orbitIndex * radiusStep;
      final speed = 1.0 / (orbitIndex * 1.5);
      final angle = (progress * speed * 2 * math.pi) +
          (i * (2 * math.pi / memories.length));

      final dx = center.dx + math.cos(angle) * radius;
      final dy = center.dy + math.sin(angle) * radius;

      canvas.drawLine(center, Offset(dx, dy), paint);
    }
  }

  @override
  bool shouldRepaint(_NeuralConnectionPainter old) =>
      old.progress != progress ||
      old.radiusStep != radiusStep ||
      old.memories != memories ||
      old.nomad != nomad;
}

class _OrbitingNode extends StatelessWidget {
  final Memory memory;
  final int index;
  final int total;
  final double progress;
  final NomadColorsExtension nomad;
  final double radiusStep;
  final VoidCallback onTap;

  const _OrbitingNode({
    required this.memory,
    required this.index,
    required this.total,
    required this.progress,
    required this.nomad,
    required this.radiusStep,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final orbitIndex = (index % 3) + 1;
    final radius = orbitIndex * radiusStep;
    final speed = 1.0 / (orbitIndex * 1.5);

    final angle =
        (progress * speed * 2 * math.pi) + (index * (2 * math.pi / total));
    final dx = math.cos(angle) * radius;
    final dy = math.sin(angle) * radius;

    // Subtle floating offset
    final floatX = math.sin(progress * 10 + index) * 5;
    final floatY = math.cos(progress * 12 + index) * 5;

    return Transform.translate(
      offset: Offset(dx + floatX, dy + floatY),
      child: BouncyTap(
        key: ValueKey('memory-${memory.id}'),
        onTap: onTap,
        tooltip: 'View ${memory.category} memory: ${memory.content}',
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: nomad.surface.withValues(alpha: 0.8),
            shape: BoxShape.circle,
          ),
          child: ClipOval(
            child: Center(
              child: Icon(
                _getCategoryIcon(memory.category),
                color: nomad.textSecondary,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
