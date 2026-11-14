import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:nomad/core/theme/nomad_theme.dart';
import 'package:nomad/core/widgets/rich_message_renderer.dart';
import 'package:nomad/features/settings/settings_screen.dart';
import 'package:nomad/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<Box> boxes;
  late File attachment;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nomad_cache_test_');
    Hive.init(directory.path);
    boxes = <Box>[];
    for (final name in [
      'chats',
      'creations',
      'settings',
      'models',
      'memories',
      'nomad_code_projects'
    ]) {
      final box = await Hive.openBox(name);
      await box.put('keep', {'value': name});
      boxes.add(box);
    }
    attachment = File('${directory.path}/attachment.jpg');
    await attachment.writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    for (final box in boxes) {
      await box.close();
    }
    await directory.delete(recursive: true);
  });

  testWidgets(
      'Clear cache preserves every stored record, preference, and attachment',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'onboarded': true,
      'selectedModelId': 'keep-model',
      'language': 'es',
      'showTokenSpeed': true,
    });
    RichMessageRenderer.clearCache();
    const RichMessageRenderer(text: '', isUser: false)
        .getOrParseSegments('Cached only');
    expect(RichMessageRenderer.cachedSourceCharacters, greaterThan(0));
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
      theme: NomadTheme.light,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const SettingsScreen(),
    )));
    await tester.pumpAndSettle();
    // The settings list builds children lazily: scroll until the Clear cache
    // tile exists in the tree before interacting with it.
    await tester.scrollUntilVisible(find.text('Clear cache'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear cache'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    for (final box in boxes) {
      expect(box.get('keep'), {'value': box.name});
    }
    expect(await tester.runAsync(() => attachment.exists()), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onboarded'), isTrue);
    expect(prefs.getString('selectedModelId'), 'keep-model');
    expect(prefs.getString('language'), 'es');
    expect(prefs.getBool('showTokenSpeed'), isTrue);
    expect(RichMessageRenderer.cachedSourceCharacters, 0);
    expect(tester.takeException(), isNull);
  });
}
