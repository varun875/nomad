/// Picks the authoritative live transcript from the latest partial result.
///
/// `speech_to_text` partials are cumulative but the recognizer rewrites them as it
/// refines ("news today" -> "news"), so the newest partial is the source of truth.
/// This returns the latest non-empty transcript, falling back to what was already
/// shown when an empty partial arrives (which would otherwise blank the UI).
String mergePartialTranscript(String previous, String next) {
  final n = next.trim();
  if (n.isEmpty) return previous.trim();
  return n;
}
