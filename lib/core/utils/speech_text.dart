/// Incrementally hides reasoning and code, including delimiters split across
/// tokens. Only a short delimiter suffix and the next spoken sentence are kept.
class SpeechTextBuffer {
  SpeechTextBuffer(this.onSentence);

  final void Function(String) onSentence;
  String _pending = '';
  String _sentence = '';
  String? _hiddenUntil;
  int _thinkDepth = 0;
  bool _closed = false;

  static const _openers = <String, String>{
    '<think>': '</think>',
    '<|think|>': '<|turn>model',
    '<|channel>': '<channel|>',
    '```': '```',
    '`': '`',
  };

  void add(String token) {
    if (_closed || token.isEmpty) return;
    _pending += token;
    _consume();
    _emitSentences();
  }

  void _consume({bool finalChunk = false}) {
    while (_pending.isNotEmpty) {
      final end = _hiddenUntil;
      if (end != null) {
        if (_pending.startsWith(end)) {
          _pending = _pending.substring(end.length);
          if (end == '</think>' && --_thinkDepth > 0) continue;
          _hiddenUntil = null;
          _sentence += ' ';
        } else if (end == '</think>' && _pending.startsWith('<think>')) {
          _thinkDepth++;
          _pending = _pending.substring(7);
        } else if (!finalChunk &&
            (end.startsWith(_pending) ||
                (end == '</think>' && '<think>'.startsWith(_pending)))) {
          return;
        } else {
          _pending = _pending.substring(1);
        }
        continue;
      }

      // Wait before interpreting a lone backtick as inline code: it may be the
      // first token of a fenced block. The same applies to partial think tags.
      if (!finalChunk &&
          _openers.keys.any((marker) =>
              marker.length > _pending.length && marker.startsWith(_pending))) {
        return;
      }
      String? opener;
      for (final marker in _openers.keys) {
        if (_pending.startsWith(marker)) {
          opener = marker;
          break;
        }
      }
      if (opener != null) {
        _hiddenUntil = _openers[opener];
        if (opener == '<think>') _thinkDepth = 1;
        _pending = _pending.substring(opener.length);
        _sentence += ' ';
      } else {
        _sentence += _pending[0];
        _pending = _pending.substring(1);
      }
    }
  }

  void _emitSentences() {
    while (_sentence.isNotEmpty) {
      final boundary = RegExp(r'[.!?](?=\s)|\n').firstMatch(_sentence);
      int split;
      if (boundary != null) {
        split = boundary.end;
      } else if (_sentence.length > 360) {
        split = _sentence.lastIndexOf(' ', 360);
        if (split < 1) split = 360;
      } else {
        return;
      }
      _emit(_sentence.substring(0, split));
      _sentence = _sentence.substring(split).trimLeft();
    }
  }

  void _emit(String text) {
    final clean = text
        .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
        .replaceAll(RegExp(r'https?://\S+'), '')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'[*_#~|]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isNotEmpty &&
        RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(clean)) {
      onSentence(clean);
    }
  }

  void finish() {
    if (_closed) return;
    _closed = true;
    // An unfinished marker or reasoning/code block is never read aloud.
    if (_hiddenUntil == null &&
        !_openers.keys.any((marker) => marker.startsWith(_pending))) {
      _consume(finalChunk: true);
    }
    _emitSentences();
    _emit(_sentence);
    _pending = '';
    _sentence = '';
  }
}
