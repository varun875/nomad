import 'package:flutter/material.dart';

import '../services/voice_session_controller.dart';
import '../theme/nomad_theme.dart';

class VoiceStatusPanel extends StatelessWidget {
  const VoiceStatusPanel({
    super.key,
    required this.session,
    required this.onTypeInstead,
    required this.onChooseModel,
    required this.onOpenSettings,
    required this.searchEnabled,
    required this.onSearchChanged,
    this.modelLoading = false,
  });

  final VoiceSessionController session;
  final VoidCallback onTypeInstead;
  final VoidCallback onChooseModel;
  final void Function(String kind) onOpenSettings;
  final bool modelLoading;
  final bool searchEnabled;
  final ValueChanged<bool> onSearchChanged;

  String get _title => switch (session.phase) {
        VoicePhase.idle => 'Nomad Voice',
        VoicePhase.starting => 'Getting ready…',
        VoicePhase.listening => 'Listening',
        VoicePhase.processing => 'Finishing your request…',
        VoicePhase.thinking =>
          modelLoading ? 'Loading your model…' : 'Thinking…',
        VoicePhase.speaking => 'Speaking',
        VoicePhase.paused => 'Voice paused',
        VoicePhase.error => 'Voice needs your attention',
      };

  String get _hint => switch (session.issue) {
        VoiceIssue.permission =>
          'Allow Microphone in app settings, then tap Try again.',
        VoiceIssue.recognizerUnavailable =>
          'Speech recognition is unavailable. Enable a speech provider in your device settings.',
        VoiceIssue.network =>
          'Speech recognition could not connect. Check your connection or your installed speech languages.',
        VoiceIssue.language =>
          'Your speech provider does not have this language available. Check its language settings.',
        VoiceIssue.audioBusy =>
          'The microphone or audio is busy. Finish the other recording or call, then try again.',
        VoiceIssue.speakerUnavailable =>
          'Spoken replies are unavailable. Check your text-to-speech engine and installed voice.',
        VoiceIssue.noModel =>
          'Choose a downloaded model to answer questions. Phone commands also work without one.',
        VoiceIssue.responseFailed =>
          'The reply could not finish. Your saved conversation is still in the chat; tap Try again to speak.',
        VoiceIssue.noSpeech =>
          'I didn’t hear a request. Tap Resume listening when you’re ready.',
        VoiceIssue.interrupted =>
          'Audio was interrupted. Tap Resume listening when you’re ready.',
        null => switch (session.phase) {
            VoicePhase.listening =>
              'Ask a question, say “open YouTube”, or “set a timer for ten minutes”.',
            VoicePhase.speaking ||
            VoicePhase.thinking =>
              'Tap the middle button to interrupt and ask something else.',
            VoicePhase.paused =>
              'The microphone is off. Resume when you’re ready.',
            VoicePhase.starting => 'Preparing the microphone and speaker…',
            _ =>
              'Your device’s speech service handles recognition. Its availability and offline support depend on your device.',
          },
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<NomadColorsExtension>()!;
    final text = Theme.of(context).textTheme;
    final needsRetry =
        session.phase == VoicePhase.error || session.phase == VoicePhase.paused;
    final settings = switch (session.issue) {
      VoiceIssue.permission => 'permission',
      VoiceIssue.speakerUnavailable => 'speech',
      VoiceIssue.recognizerUnavailable ||
      VoiceIssue.language ||
      VoiceIssue.network =>
        'recognition',
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: colors.border),
        ),
        constraints: BoxConstraints(
            maxHeight:
                (MediaQuery.sizeOf(context).height * .32).clamp(130, 250)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_title,
                  key: const ValueKey('voice-status'), style: text.titleMedium),
              const SizedBox(height: 6),
              if (session.transcript.isNotEmpty) ...[
                Text(session.transcript,
                    key: const ValueKey('voice-transcript'),
                    style: text.bodyMedium),
                const SizedBox(height: 6),
              ],
              Text(_hint,
                  style: text.bodySmall?.copyWith(color: colors.textSecondary)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: [
                  if (needsRetry)
                    TextButton.icon(
                      onPressed: session.retry,
                      icon: const Icon(Icons.mic_rounded, size: 18),
                      label: Text(session.phase == VoicePhase.paused
                          ? 'Resume listening'
                          : 'Try again'),
                    ),
                  if (settings != null)
                    TextButton(
                        onPressed: () => onOpenSettings(settings),
                        child: const Text('Open settings')),
                  if (session.issue == VoiceIssue.noModel)
                    TextButton(
                        onPressed: onChooseModel,
                        child: const Text('Choose model')),
                  TextButton(
                      onPressed: onTypeInstead,
                      child: const Text('Type instead')),
                  TextButton.icon(
                    onPressed: session.isResponding
                        ? null
                        : () => onSearchChanged(!searchEnabled),
                    icon: Icon(
                        searchEnabled
                            ? Icons.public_rounded
                            : Icons.public_off_rounded,
                        size: 16),
                    label: Text(
                        searchEnabled ? 'Web search on' : 'Web search off'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
