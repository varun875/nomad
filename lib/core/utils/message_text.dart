// Pure helpers for inspecting/normalizing model output text.
//
// Extracted from the chat screen so they can be unit-tested without a widget
// tree.

final _channelRegex = RegExp(
  r'<\|channel>([\s\S]*?)<channel\|>',
  dotAll: true,
);
final _thinkRegex = RegExp(
  r'<\|think\|>\s*\n?([\s\S]*?)(?:<\|turn>model|$)',
  dotAll: true,
);
final _legacyThinkRegex = RegExp(r'<think>([\s\S]*?)</think>', dotAll: true);

/// Extract the model's "thinking" text from the supported reasoning formats
/// (`<|channel>thought ... <channel|>`, `<|think|> ...`, `<think> ... </think>`).
/// Returns an empty string when no thinking content is present.
String extractThinking(String text) {
  final channelMatch = _channelRegex.firstMatch(text);
  if (channelMatch != null) {
    var content = channelMatch.group(1)!.trim();
    if (content.startsWith('thought')) {
      content = content.substring('thought'.length).trim();
    }
    if (content.isNotEmpty) return content;
  }

  final thinkMatch = _thinkRegex.firstMatch(text);
  if (thinkMatch != null) {
    final content = thinkMatch.group(1)!.trim();
    if (content.isNotEmpty) return content;
  }

  final legacyMatch = _legacyThinkRegex.firstMatch(text);
  if (legacyMatch != null) return legacyMatch.group(1)!.trim();

  return '';
}

/// Remove thinking-tag wrappers, leaving only the visible reply text.
String stripThinkingTags(String text) {
  return text
      .replaceAll(RegExp(r'<\|channel>[\s\S]*?<channel\|>', dotAll: true), '')
      .replaceAll(
        RegExp(r'<\|think\|>\s*\n?[\s\S]*?(?:<\|turn>model|$)', dotAll: true),
        '',
      )
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', dotAll: true), '')
      .trim();
}

/// Heuristic for whether a streamed reply looks like it was cut off mid-token
/// (trailing punctuation/hyphen or an unclosed code fence). Used to trigger a
/// follow-up generation pass.
bool looksTruncated(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  if (trimmed.endsWith(',') ||
      trimmed.endsWith(':') ||
      trimmed.endsWith(';')) {
    return true;
  }
  if (trimmed.endsWith('-') || trimmed.endsWith('\u2014')) {
    return true;
  }
  if (trimmed.contains('```') && trimmed.split('```').length.isEven) {
    return true;
  }
  return false;
}
