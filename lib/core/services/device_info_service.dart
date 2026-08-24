import 'dart:io';
import 'package:flutter/services.dart';

/// Single source of truth for device hardware info.
///
/// Consolidates the RAM-detection logic that used to live in both
/// [ModelService] and [InferenceService]: the MethodChannel call on mobile and
/// the `sysctl`/`free`/`powershell` probes on desktop.
class DeviceInfo {
  static const _channel = MethodChannel('com.varun.nomad/storage');

  /// Synchronous, best-effort total physical RAM in MB, or null if it could
  /// not be detected. Used where a synchronous value is required (e.g. GPU
  /// layer selection at model load time).
  static int? totalMemoryMB() {
    try {
      if (Platform.isMacOS) {
        final result = Process.runSync('sysctl', ['-n', 'hw.memsize']);
        if (result.exitCode == 0) {
          final bytes = int.tryParse(result.stdout.toString().trim());
          if (bytes != null && bytes > 0) return bytes ~/ (1024 * 1024);
        }
      } else if (Platform.isLinux) {
        final result = Process.runSync('free', ['-b']);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().trim().split('\n');
          if (lines.length > 1) {
            final parts = lines[1].split(RegExp(r'\s+'));
            if (parts.length > 1) {
              final bytes = int.tryParse(parts[1]);
              if (bytes != null && bytes > 0) return bytes ~/ (1024 * 1024);
            }
          }
        }
      } else if (Platform.isWindows) {
        final result = Process.runSync('powershell', [
          '-NoProfile',
          '-Command',
          '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory',
        ]);
        if (result.exitCode == 0) {
          final bytes = int.tryParse(result.stdout.toString().trim());
          if (bytes != null && bytes > 0) return bytes ~/ (1024 * 1024);
        }
      }
    } catch (_) {}
    return null;
  }

  /// Total physical RAM in GB (rounded), for model selection.
  ///
  /// Mobile uses the native MethodChannel; desktop uses [totalMemoryMB].
  /// Falls back to 3 GB on mobile and 16 GB on desktop when detection fails.
  static Future<int> deviceRamGB() async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final memoryBytes = await _channel.invokeMethod<int>('getDeviceRAM');
        if (memoryBytes == null || memoryBytes <= 0) return 3;
        return (memoryBytes / (1024 * 1024 * 1024)).round();
      } on PlatformException {
        return 3;
      } catch (_) {
        return 3;
      }
    }
    final mb = totalMemoryMB();
    return mb == null ? 16 : (mb / 1024).round();
  }
}
