import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nomad/core/theme/nomad_theme.dart';
import 'package:nomad/features/creations/creation_preview.dart';
import 'package:nomad/l10n/app_localizations.dart';
import 'package:webview_all_windows/webview_all_windows.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';

class _Platform extends WindowsWebViewPlatform {
  WindowsWebViewController? controller;
  @override
  WindowsWebViewController createPlatformWebViewController(
      PlatformWebViewControllerCreationParams params) {
    return controller = super.createPlatformWebViewController(params);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('WebView2 renders local creations and blocks external navigation',
      (tester) async {
    final environment = ProviderContainer();
    try {
      await environment.read(creationWindowsPlatformProvider)();
    } finally {
      environment.dispose();
    }
    final platform = _Platform();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          creationWindowsPlatformProvider
              .overrideWithValue(() async => platform),
        ],
        child: MaterialApp(
            theme: NomadTheme.light,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
                body: CreationPreview(
              html: '<!doctype html><html><body><h1>Nomad preview check</h1>'
                  '<script>window.nomadPreviewCheck = 42;</script></body></html>',
            )))));
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (platform.controller != null &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    expect(find.byType(CreationPreviewError), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final controller = platform.controller!;
    final value = await controller
        .runJavaScriptReturningResult('window.nomadPreviewCheck');
    expect(value.toString(), contains('42'));
    await controller.runJavaScript(
        'window.location.href = "https://example.invalid/blocked";');
    await tester.pump(const Duration(seconds: 2));
    final stillLocal = await controller
        .runJavaScriptReturningResult('window.nomadPreviewCheck');
    expect(stillLocal.toString(), contains('42'));
    expect(find.byType(CreationPreviewError), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));
}
