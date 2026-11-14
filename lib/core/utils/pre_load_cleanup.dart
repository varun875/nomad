import 'package:flutter/painting.dart';

/// Frees render-side memory just before a native model allocation.
///
/// [run] clears the Flutter image cache and then invokes registered hooks so
/// feature layers (e.g. Creations webview controllers) can release their own
/// heavyweight resources before llama.cpp allocates model weights.
class PreLoadCleanup {
  PreLoadCleanup._();

  static final List<void Function()> _hooks = [];

  /// Register a release callback; called on every [run].
  static void register(void Function() hook) => _hooks.add(hook);

  static void run() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    for (final hook in List.of(_hooks)) {
      try {
        hook();
      } catch (_) {
        // A failing hook must never block a model load.
      }
    }
  }
}
