import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Android voice-assistant wiring: the manifest must declare every
/// component the framework is told to bind, and the voice-interaction metadata
/// must not point at a class that isn't declared (which is what made the
/// recognition service non-functional).
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final assistantXml =
      File('android/app/src/main/res/xml/assistant_service.xml')
          .readAsStringSync();

  test('manifest declares the voice interaction and session services', () {
    expect(manifest, contains('android:name=".AssistantService"'));
    expect(manifest, contains('android:name=".AssistantSessionService"'));
  });

  test('metadata session service resolves to a declared component', () {
    final session = RegExp(r'android:sessionService="([^"]+)"')
        .firstMatch(assistantXml)!
        .group(1)!;
    expect(session, 'com.varun.nomad.AssistantSessionService');
    // The class the metadata names must be registered in the manifest.
    final simple = session.split('.').last;
    expect(manifest, contains('android:name=".$simple"'));
  });

  test(
      'the referenced recognition service is declared and permission protected',
      () {
    final recognition = RegExp(r'android:recognitionService="([^"]+)"')
        .firstMatch(assistantXml)!
        .group(1)!;
    expect(recognition, 'com.varun.nomad.NomadRecognitionService');
    final service = RegExp(
            r'<service\s+android:name="\.NomadRecognitionService"[\s\S]*?</service>')
        .firstMatch(manifest)!
        .group(0)!;
    expect(service,
        contains('android.permission.BIND_SPEECH_RECOGNITION_SERVICE'));
    expect(service, contains('android.speech.RecognitionService'));
  });

  test('voice uses audio focus instead of changing device stream volumes', () {
    final activity =
        File('android/app/src/main/kotlin/com/varun/nomad/MainActivity.kt')
            .readAsStringSync();
    expect(activity, contains('requestAudioFocus'));
    expect(activity, contains('abandonAudioFocusRequest'));
    expect(activity, isNot(contains('setStreamVolume')));
    expect(activity, isNot(contains('getStreamMaxVolume')));
    expect(manifest, isNot(contains('ACCESS_NOTIFICATION_POLICY')));
  });

  test('assistant launch intents are registered on MainActivity', () {
    expect(manifest, contains('android:name=".MainActivity"'));
    expect(manifest, contains('android.intent.action.ASSIST'));
    expect(manifest, contains('android.intent.action.VOICE_COMMAND'));
  });
}
