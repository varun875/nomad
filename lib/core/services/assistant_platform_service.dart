import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AssistantLaunch {
  const AssistantLaunch({required this.id, this.prompt, this.voice = true});
  final String id;
  final String? prompt;
  final bool voice;

  static AssistantLaunch? fromMap(Object? value) {
    if (value is! Map || value['id'] is! String) return null;
    final prompt = value['prompt'];
    return AssistantLaunch(
      id: value['id'] as String,
      prompt:
          prompt is String && prompt.trim().isNotEmpty ? prompt.trim() : null,
      voice: value['voice'] != false,
    );
  }
}

final assistantPlatformProvider = Provider<AssistantPlatformService>((ref) {
  final service = AssistantPlatformService();
  ref.onDispose(service.dispose);
  return service;
});

/// Launch events live above navigation, so they also work from Settings, Code,
/// onboarding, and when Android delivers onNewIntent to an already-visible app.
class AssistantPlatformService {
  AssistantPlatformService({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel('com.varun.nomad/assistant'),
        isAndroid = isAndroid ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool isAndroid;
  final _launches = StreamController<AssistantLaunch>.broadcast();
  final _interruptions = StreamController<void>.broadcast();
  Stream<AssistantLaunch> get launches => _launches.stream;
  Stream<void> get interruptions => _interruptions.stream;
  String? _lastLaunch;
  bool _started = false;
  bool _disposed = false;
  Future<void> _checking = Future.value();

  Future<void> start() async {
    if (!isAndroid || _started || _disposed) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (_disposed) return;
      if (call.method == 'assistantInvoked') await checkPendingLaunch();
      if (call.method == 'audioFocusLost') _interruptions.add(null);
    });
    await checkPendingLaunch();
  }

  Future<void> checkPendingLaunch() {
    if (!isAndroid || _disposed) return Future.value();
    // Serialize every consume, including multiple notifications received during
    // the first read. Each one rechecks for a newer pending native invocation.
    _checking = _checking.then((_) async {
      if (!_disposed) await _consumeLaunch();
    });
    return _checking;
  }

  Future<void> _consumeLaunch() async {
    try {
      final launch =
          AssistantLaunch.fromMap(await _channel.invokeMethod('consumeLaunch'));
      if (_disposed || launch == null || launch.id == _lastLaunch) return;
      _lastLaunch = launch.id;
      _launches.add(launch);
    } on PlatformException {
      // The next resume can retry a temporarily unavailable native channel.
    } on MissingPluginException {
      // Non-Android test hosts do not have an assistant activity.
    }
  }

  Future<bool> requestAudioFocus() async {
    if (!isAndroid) return true;
    return await _channel.invokeMethod<bool>('requestAudioFocus') ?? false;
  }

  Future<void> releaseAudioFocus() async {
    if (isAndroid) await _channel.invokeMethod<void>('releaseAudioFocus');
  }

  Future<bool> isSpeechRecognitionAvailable() async {
    if (!isAndroid) return true;
    return await _channel.invokeMethod<bool>('isSpeechRecognitionAvailable') ??
        false;
  }

  Future<bool> openSettings(String kind) async {
    if (!isAndroid) return false;
    return await _channel.invokeMethod<bool>('openSettings', {'kind': kind}) ??
        false;
  }

  Future<Map<String, dynamic>> executeAction(
      String action, Map<String, Object> arguments) async {
    if (!isAndroid) {
      return {
        'success': false,
        'message': 'Phone actions are available on Android.'
      };
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'executeAction',
      {'action': action, ...arguments},
    );
    return result ??
        {
          'success': false,
          'message': 'That action is not available on this device.'
        };
  }

  void dispose() {
    _disposed = true;
    if (_started) _channel.setMethodCallHandler(null);
    unawaited(_launches.close());
    unawaited(_interruptions.close());
  }
}
