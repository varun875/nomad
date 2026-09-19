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
      File('android/app/src/main/res/xml/assistant_service.xml').readAsStringSync();

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

  test('no recognition service is referenced or declared', () {
    // AssistantSession runs its own SpeechRecognizer, so a RecognitionService is
    // not required. If one is reintroduced it must be declared below.
    expect(assistantXml, isNot(contains('recognitionService')));
    expect(manifest, isNot(contains('AssistantRecognitionService')));
  });

  test('assistant launch intents are registered on MainActivity', () {
    expect(manifest, contains('android:name=".MainActivity"'));
    expect(manifest, contains('android.intent.action.ASSIST'));
    expect(manifest, contains('android.intent.action.VOICE_COMMAND'));
  });
}
