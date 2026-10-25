import 'dart:ui' show PointerDeviceKind, SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/theme/nomad_theme.dart';
import 'package:nomad/core/widgets/nomad_animations.dart';
import 'package:nomad/core/widgets/nomad_widgets.dart';
import 'package:nomad/l10n/app_localizations.dart';

Widget _app(
  Widget child, {
  bool disableAnimations = false,
  Locale locale = const Locale('en'),
}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    // Exercise controls without the production theme's runtime font loading.
    theme: ThemeData(
      colorScheme: const ColorScheme.light(primary: NomadColors.lightText),
      extensions: const [
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
        ),
      ],
    ),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  setUp(() {
    final strategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = strategy);
  });

  testWidgets('BouncyTap supports Tab, Enter and Space', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(BouncyTap(
      onTap: () => taps++,
      tooltip: 'Run action',
      semanticLabel: 'Run',
      child: const Text('Run action'),
    )));

    final control = find.byType(BouncyTap);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final data = tester.getSemantics(control).getSemanticsData();
    expect(data.label, 'Run');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isTrue);
    expect(data.flagsCollection.isFocused, Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    final decoration = tester
        .widget<DecoratedBox>(find.descendant(
          of: control,
          matching: find.byType(DecoratedBox),
        ))
        .decoration as ShapeDecoration;
    expect((decoration.shape as RoundedRectangleBorder).side.width, 2);

    for (final key in [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.numpadEnter,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
    expect(taps, 3);
  });

  testWidgets('BouncyTap disabled controls skip focus and feedback',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const BouncyTap(
          key: ValueKey('disabled'),
          child: SizedBox(width: 120, height: 48, child: Text('Disabled')),
        ),
        BouncyTap(
          key: const ValueKey('enabled'),
          onTap: () => taps++,
          child: const SizedBox(width: 120, height: 48, child: Text('Enabled')),
        ),
      ],
    )));
    final disabled = find.byKey(const ValueKey('disabled'));
    final enabled = find.byKey(const ValueKey('enabled'));
    final data = tester.getSemantics(disabled).getSemanticsData();
    expect(data.label, 'Disabled');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.flagsCollection.isFocused, Tristate.none);
    expect(data.hasAction(SemanticsAction.tap), isFalse);
    expect(data.hasAction(SemanticsAction.longPress), isFalse);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(enabled));
    await tester.pumpAndSettle();
    final hover = tester
        .widget<DecoratedBox>(find.descendant(
          of: enabled,
          matching: find.byType(DecoratedBox),
        ))
        .decoration as ShapeDecoration;
    expect(hover.color, isNot(Colors.transparent));
    expect(
        tester
            .widget<FocusableActionDetector>(find.descendant(
              of: enabled,
              matching: find.byType(FocusableActionDetector),
            ))
            .mouseCursor,
        SystemMouseCursors.click);

    await mouse.moveTo(tester.getCenter(disabled));
    await tester.pumpAndSettle();
    final noHover = tester
        .widget<DecoratedBox>(find.descendant(
          of: disabled,
          matching: find.byType(DecoratedBox),
        ))
        .decoration as ShapeDecoration;
    expect(noHover.color, Colors.transparent);
    expect(
        tester
            .widget<FocusableActionDetector>(find.descendant(
              of: disabled,
              matching: find.byType(FocusableActionDetector),
            ))
            .mouseCursor,
        SystemMouseCursors.basic);
    await mouse.removePointer();

    final press = await tester.startGesture(tester.getCenter(disabled));
    await tester.pump(NomadDurations.tap);
    expect(
        tester
            .widget<Transform>(find.descendant(
              of: disabled,
              matching: find.byType(Transform),
            ))
            .transform
            .entry(0, 0),
        1);
    expect(
        tester
            .widget<Opacity>(find.descendant(
              of: disabled,
              matching: find.byType(Opacity),
            ))
            .opacity,
        lessThan(1));
    await press.up();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(tester.getSemantics(enabled).flagsCollection.isFocused,
        Tristate.isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(taps, 2);
  });

  testWidgets('BouncyTap preserves tap and long press with a tooltip',
      (tester) async {
    var taps = 0;
    var longPresses = 0;
    await tester.pumpWidget(_app(BouncyTap(
      onTap: () => taps++,
      onLongPress: () => longPresses++,
      tooltip: 'More actions',
      child: const Text('Actions'),
    )));
    await tester.tap(find.byType(BouncyTap));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(BouncyTap));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(longPresses, 1);
  });

  testWidgets(
      'BouncyTap supports keyboard activation for long-press-only controls',
      (tester) async {
    var activations = 0;
    await tester.pumpWidget(_app(BouncyTap(
      onLongPress: () => activations++,
      child: const Text('More actions'),
    )));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(activations, 1);
  });

  testWidgets('BouncyTap respects reduced-motion changes', (tester) async {
    var taps = 0;
    final button = BouncyTap(
      onTap: () => taps++,
      child: const SizedBox.square(dimension: 48, child: Icon(Icons.add)),
    );
    final control = find.byType(BouncyTap);
    double scale() => tester
        .widget<Transform>(find.descendant(
          of: control,
          matching: find.byType(Transform),
        ))
        .transform
        .entry(0, 0);

    await tester.pumpWidget(_app(button));
    final press = await tester.startGesture(tester.getCenter(control));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(NomadDurations.tap);
    expect(scale(), lessThan(1));

    await tester.pumpWidget(_app(button, disableAnimations: true));
    expect(scale(), 1);
    await press.up();
    await tester.pumpAndSettle();

    final reducedPress = await tester.startGesture(tester.getCenter(control));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(NomadDurations.tap);
    expect(scale(), 1);
    await reducedPress.up();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
      await tester.sendKeyEvent(key);
      await tester.pump(NomadDurations.tap);
      expect(scale(), 1);
    }
    expect(taps, 4);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final streaming in [false, true]) {
    final action = streaming ? 'stop' : 'send';
    testWidgets('NomadSendButton $action has a 48px labeled hit target',
        (tester) async {
      var sends = 0;
      var stops = 0;
      await tester.pumpWidget(_app(NomadSendButton(
        isEnabled: !streaming,
        isStreaming: streaming,
        onTap: () => sends++,
        onStop: () => stops++,
      )));
      await tester.pumpAndSettle();

      final control = find.byType(BouncyTap);
      final size = tester.getSize(control);
      final label = streaming ? 'Stop generating' : 'Send message';
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(find.byTooltip(label), findsOneWidget);
      final node = tester.getSemantics(control);
      expect(node.getSemanticsData().label, label);
      expect(node.rect.width, greaterThanOrEqualTo(48));
      expect(node.rect.height, greaterThanOrEqualTo(48));

      // This point is inside the target but outside the 36px visual circle.
      await tester
          .tapAt(tester.getTopLeft(control) + Offset(2, size.height / 2));
      await tester.pumpAndSettle();
      expect(sends, streaming ? 0 : 1);
      expect(stops, streaming ? 1 : 0);
    });
  }

  testWidgets('NomadSendButton disables unavailable send and stop actions',
      (tester) async {
    var sends = 0;
    await tester.pumpWidget(_app(Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NomadSendButton(isEnabled: false, onTap: () => sends++),
        const NomadSendButton(isEnabled: true),
        const NomadSendButton(isEnabled: true, isStreaming: true),
      ],
    )));
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      final control = find.byType(BouncyTap).at(i);
      final data = tester.getSemantics(control).getSemanticsData();
      expect(data.flagsCollection.isEnabled, Tristate.isFalse);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      await tester.tap(control);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(sends, 0);
  });

  testWidgets(
      'NomadBackButton localizes its default label and respects overrides',
      (tester) async {
    await tester.pumpWidget(_app(
      NomadBackButton(onTap: () {}),
      locale: const Locale('es'),
    ));
    await tester.pumpAndSettle();
    final label =
        AppLocalizations.of(tester.element(find.byType(NomadBackButton)))!.back;
    expect(find.text(label), findsOneWidget);
    expect(find.byTooltip(label), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(BouncyTap)).getSemanticsData().label,
      label,
    );

    await tester.pumpWidget(_app(
      NomadBackButton(onTap: () {}, label: 'Return'),
      locale: const Locale('es'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Return'), findsOneWidget);
    expect(find.byTooltip('Return'), findsOneWidget);
  });
}
