import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/theme/nomad_theme.dart';
import '../../l10n/app_localizations.dart';
import 'creations_screen.dart';

class CreationAppScreen extends ConsumerStatefulWidget {
  final String creationId;
  const CreationAppScreen({super.key, required this.creationId});

  @override
  ConsumerState<CreationAppScreen> createState() => _CreationAppScreenState();
}

class _CreationAppScreenState extends ConsumerState<CreationAppScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            // loadHtmlString uses about:blank; block any prompt-injected
            // navigation or exfiltration to external hosts.
            if (request.url == 'about:blank' ||
                request.url.startsWith('data:') ||
                request.url.startsWith('blob:')) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
          onPageFinished: (String url) {
            if (mounted) setState(() => _isLoading = false);
          },
          onWebResourceError: (WebResourceError error) {
            if (mounted) setState(() => _error = error.description);
          },
        ),
      );
    _loadCreation();
  }

  void _loadCreation() {
    final creations = ref.read(creationsProvider);
    try {
      final creation = creations.firstWhere((c) => c.id == widget.creationId);
      _controller.loadHtmlString(creation.html);
    } catch (e) {
      setState(() {
        _error = AppLocalizations.of(context)!.creationNotFound;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final nomad = Theme.of(context).extension<NomadColorsExtension>()!;
    final brightness = Theme.of(context).brightness;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: brightness == Brightness.dark ? Brightness.light : Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Colors.white, // Most HTML apps expect a white background
        body: Stack(
          children: [
            if (_error != null)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline_rounded, size: 48, color: nomad.textSecondary),
                    const SizedBox(height: 16),
                    Text(_error!, style: TextStyle(color: nomad.textPrimary)),
                    const SizedBox(height: 24),
                    TextButton(
                      onPressed: () { HapticFeedback.lightImpact(); Navigator.of(context).pop(); },
                      child: Text(AppLocalizations.of(context)!.goBack),
                    ),
                  ],
                ),
              )
            else
              SafeArea(
                bottom: false,
                child: WebViewWidget(controller: _controller),
              ),
            
            if (_isLoading && _error == null)
              Center(
                child: CircularProgressIndicator(color: nomad.textPrimary),
              ),

            // Subtle close button for "App" feel but still allowing exit
            if (!_isLoading)
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              right: 20,
              child: Opacity(
                opacity: 0.3,
                child: GestureDetector(
                  onTap: () { HapticFeedback.lightImpact(); Navigator.of(context).pop(); },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, size: 16, color: Colors.black),
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
