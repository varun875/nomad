import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_all_windows/webview_all_windows.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart'
    as windows;

import '../../core/theme/nomad_theme.dart';
import '../../l10n/app_localizations.dart';

final creationWindowsPlatformProvider =
    Provider<Future<WindowsWebViewPlatform> Function()>((ref) => () async {
          final directory = await getApplicationSupportDirectory();
          await WindowsWebViewController.ensureEnvironment(
            userDataPath: '${directory.path}/creations_webview2',
          );
          return WindowsWebViewPlatform();
        });

String creationHtmlWithCsp(String html) {
  const csp = '<meta http-equiv="Content-Security-Policy" '
      'content="default-src \'none\'; script-src \'unsafe-inline\'; '
      'style-src \'unsafe-inline\'; img-src data: blob:; '
      'font-src data:; media-src data: blob:; connect-src \'none\'; '
      'frame-src \'none\'; object-src \'none\'; base-uri \'none\'; '
      'form-action \'none\'">';
  // Policies intersect, so a page-supplied CSP cannot relax this policy.
  return '$csp\n$html';
}

bool isLocalCreationUrl(String url) =>
    url == 'about:blank' || url.startsWith('data:') || url.startsWith('blob:');

/// Tracks live creation preview webviews so inactive previews can be
/// unmounted/disposed before a native model load. The most recently
/// initialized preview is treated as active (the creation on screen).
class CreationWebviewRegistry {
  CreationWebviewRegistry._();

  static final Map<Object, void Function()> _releases = {};
  static Object? _activeKey;

  static void register(Object key, void Function() release) {
    _releases[key] = release;
    _activeKey = key;
  }

  static void unregister(Object key) {
    _releases.remove(key);
    if (_activeKey == key) _activeKey = null;
  }

  /// Unmounts every registered preview except the active one so their webview
  /// memory is available for the model allocation. Released previews reload
  /// when they are tapped again.
  static void releaseInactive() {
    for (final entry in _releases.entries.toList()) {
      if (entry.key == _activeKey) continue;
      _releases.remove(entry.key);
      try {
        entry.value();
      } catch (_) {}
    }
  }
}

class CreationPreview extends ConsumerStatefulWidget {
  const CreationPreview({super.key, required this.html});

  final String html;

  @override
  ConsumerState<CreationPreview> createState() => _CreationPreviewState();
}

class _CreationPreviewState extends ConsumerState<CreationPreview> {
  WindowsWebViewController? _windowsController;
  Widget? _view;
  bool _loading = true;
  bool _released = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      if (kIsWeb) {
        throw UnsupportedError(
            'Embedded creation previews are not available on the web.');
      }
      final html = creationHtmlWithCsp(widget.html);
      CreationWebviewRegistry.register(this, _release);
      switch (defaultTargetPlatform) {
        case TargetPlatform.windows:
          final platform = await ref.read(creationWindowsPlatformProvider)();
          if (!mounted) return;
          final controller = platform.createPlatformWebViewController(
            const WindowsWebViewControllerCreationParams(
              popupWindowPolicy: WindowsPopupWindowPolicy.deny,
              devToolsEnabled: false,
              browserAcceleratorKeysEnabled: false,
              downloadsEnabled: false,
            ),
          );
          _windowsController = controller;
          final delegate = platform.createPlatformNavigationDelegate(
            const windows.PlatformNavigationDelegateCreationParams(),
          );
          await delegate.setOnNavigationRequest((request) =>
              isLocalCreationUrl(request.url)
                  ? windows.NavigationDecision.navigate
                  : windows.NavigationDecision.prevent);
          await delegate.setOnPageFinished((_) => _finishLoading());
          await delegate.setOnWebResourceError((error) {
            if (error.isForMainFrame != false) _fail(error.description);
          });
          // This plugin cancels NavigationStarting before consulting Dart.
          // Await the policy and native restrictions before loading any HTML.
          await controller.setPlatformNavigationDelegate(delegate);
          await controller.setOnPlatformPermissionRequest((request) {
            request.deny();
          });
          await controller
              .setJavaScriptMode(windows.JavaScriptMode.unrestricted);
          await controller.setBackgroundColor(Colors.white);
          if (!mounted) return;
          final view = platform.createPlatformWebViewWidget(
            windows.PlatformWebViewWidgetCreationParams(controller: controller),
          );
          setState(() => _view = view.build(context));
          await controller.loadHtmlString(html);
          break;
        case TargetPlatform.android:
        case TargetPlatform.iOS:
        case TargetPlatform.macOS:
          final controller = WebViewController();
          await controller.setNavigationDelegate(NavigationDelegate(
            onNavigationRequest: (request) => isLocalCreationUrl(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
            onPageFinished: (_) => _finishLoading(),
            onWebResourceError: (error) {
              if (error.isForMainFrame != false) _fail(error.description);
            },
          ));
          await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
          await controller.setBackgroundColor(Colors.white);
          if (!mounted) return;
          setState(() => _view = WebViewWidget(controller: controller));
          await controller.loadHtmlString(html);
          break;
        case TargetPlatform.linux:
        case TargetPlatform.fuchsia:
          throw UnsupportedError(
              'Embedded creation previews are not available on this platform.');
      }
    } catch (error) {
      if (error is PlatformException &&
          error.code == 'webview2_runtime_unavailable') {
        _fail(
            'Install or update Microsoft Edge WebView2 Runtime, then reopen this creation.');
      } else {
        _fail('Could not start the creation preview: $error');
      }
    }
  }

  void _finishLoading() {
    if (mounted) setState(() => _loading = false);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  /// Unmounts this preview's webview and releases its controllers so the
  /// memory is available for a model load. The preview reloads when tapped.
  void _release() {
    _windowsController?.dispose().ignore();
    _windowsController = null;
    // Dropping the view unmounts the platform webview and releases the
    // mobile controller it references.
    _view = null;
    _loading = false;
    _released = true;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    CreationWebviewRegistry.unregister(this);
    // The Windows controller owns its texture and WebView2 instance, including
    // initialization still in flight when the user closes the viewer.
    _windowsController?.dispose().ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return CreationPreviewError(message: _error!);
    if (_released) {
      return GestureDetector(
        onTap: () {
          setState(() {
            _released = false;
            _loading = true;
          });
          _initialize();
        },
        child: const ColoredBox(
          color: Colors.white,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return ColoredBox(
      color: Colors.white,
      child: Stack(
        children: [
          if (_view != null) Positioned.fill(child: _view!),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

class CreationPreviewError extends StatelessWidget {
  const CreationPreviewError({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 48, color: nomad.textSecondary),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: nomad.textPrimary)),
            const SizedBox(height: 24),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: Text(l10n.retry)),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(l10n.goBack),
            ),
          ],
        ),
      ),
    );
  }
}
