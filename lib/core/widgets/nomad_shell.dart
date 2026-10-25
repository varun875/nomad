import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../constants/responsive.dart';
import '../theme/nomad_theme.dart';
import '../providers/sidebar_provider.dart';
import '../../features/chat/chat_history_screen.dart';

class TabNavigationInfo extends InheritedWidget {
  final int previousIndex;
  final int currentIndex;

  const TabNavigationInfo({
    super.key,
    required this.previousIndex,
    required this.currentIndex,
    required super.child,
  });

  static TabNavigationInfo? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<TabNavigationInfo>();
  }

  @override
  bool updateShouldNotify(TabNavigationInfo oldWidget) {
    return previousIndex != oldWidget.previousIndex ||
        currentIndex != oldWidget.currentIndex;
  }
}

class NomadShell extends ConsumerStatefulWidget {
  final Widget child;

  const NomadShell({super.key, required this.child});

  @override
  ConsumerState<NomadShell> createState() => _NomadShellState();
}

class _NomadShellState extends ConsumerState<NomadShell> {
  int _currentIndex = 0;
  int _previousIndex = 0;
  double _sidebarWidth = 280.0;
  static const double _minSidebarWidth = 240.0;
  static const double _maxSidebarWidth = 360.0;
  bool _isDragging = false;

  int _getIndexFromLocation(String location) {
    const destinations = [
      '/home',
      '/code',
      '/creations',
      '/you',
      '/skills',
      '/settings/models',
      '/settings',
    ];
    for (var index = 0; index < destinations.length; index++) {
      if (location.startsWith(destinations[index])) return index;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final isSidebarOpen = ref.watch(sidebarOpenProvider);
    final location = GoRouter.of(context).location;
    final nextIndex = _getIndexFromLocation(location);
    if (nextIndex != _currentIndex) {
      _previousIndex = _currentIndex;
      _currentIndex = nextIndex;
    }
    final fullWidth = location == '/home' ||
        location.startsWith('/code') ||
        location.startsWith('/assistant');

    final body = TabNavigationInfo(
      previousIndex: _previousIndex,
      currentIndex: _currentIndex,
      child: isDesktop && !fullWidth
          ? ResponsiveCenter(child: widget.child)
          : widget.child,
    );

    return Scaffold(
      backgroundColor: nomad.background,
      resizeToAvoidBottomInset: false,
      body: Row(
        children: [
          if (isDesktop)
            AnimatedContainer(
              duration: _isDragging || MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              width: isSidebarOpen ? _sidebarWidth + 8.0 : 0.0,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerRight,
                  minWidth: _sidebarWidth + 8.0,
                  maxWidth: _sidebarWidth + 8.0,
                  child: Row(
                    children: [
                      SizedBox(
                        width: _sidebarWidth,
                        child: ExcludeFocus(
                          excluding: !isSidebarOpen,
                          child: ExcludeSemantics(
                            excluding: !isSidebarOpen,
                            child: RepaintBoundary(
                              child: ChatHistoryScreen(
                                currentLocation: location,
                              ),
                            ),
                          ),
                        ),
                      ),
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onPanStart: (_) => setState(() => _isDragging = true),
                          onPanUpdate: (details) {
                            setState(() {
                              _sidebarWidth += details.delta.dx;
                              if (_sidebarWidth < _minSidebarWidth) {
                                _sidebarWidth = _minSidebarWidth;
                              } else if (_sidebarWidth > _maxSidebarWidth) {
                                _sidebarWidth = _maxSidebarWidth;
                              }
                            });
                          },
                          onPanEnd: (_) => setState(() => _isDragging = false),
                          onPanCancel: () =>
                              setState(() => _isDragging = false),
                          child: Container(
                            width: 8,
                            alignment: Alignment.center,
                            child: Container(width: 1, color: nomad.border),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            // The nested route must not block the sibling navigation semantics.
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              child: RepaintBoundary(child: body),
            ),
          ),
        ],
      ),
    );
  }
}
