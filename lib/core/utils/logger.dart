import 'package:flutter/foundation.dart';

/// Lightweight, zero-cost logger that is stripped from release builds.
///
/// Every call is gated behind [kDebugMode], so the Dart compiler tree-shakes
/// the entire body in profile/release mode — zero runtime cost.
///
/// Usage:
/// ```dart
/// Log.d('Download', 'Starting download for $id');
/// Log.e('Download', 'File not found at $path');
/// Log.w('Search', 'No API key configured');
/// ```
abstract class Log {
  /// Debug-level log – routine progress, lifecycle events.
  static void d(String tag, String message) {
    if (kDebugMode) debugPrint('[$tag] $message');
  }

  /// Warning – something unexpected but recoverable.
  static void w(String tag, String message) {
    if (kDebugMode) debugPrint('⚠ [$tag] $message');
  }

  /// Error – something broke.
  static void e(String tag, String message, [Object? error, StackTrace? stack]) {
    if (kDebugMode) {
      debugPrint('✖ [$tag] $message');
      if (error != null) debugPrint('  Error: $error');
      if (stack != null) debugPrint('  $stack');
    }
  }
}
