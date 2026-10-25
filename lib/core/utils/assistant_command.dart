import 'package:intl/intl.dart';

/// Common device requests do not need a loaded language model. Matching is
/// anchored to the request, so discussing an action does not execute it.
class AssistantCommand {
  const AssistantCommand(this.action, [this.arguments = const {}])
      : response = null;
  const AssistantCommand.reply(String text)
      : action = 'reply',
        arguments = const {},
        response = text;

  final String action;
  final Map<String, Object> arguments;
  final String? response;

  static AssistantCommand? parse(String input, {DateTime? now}) {
    final text = input
        .trim()
        .toLowerCase()
        .replaceFirst(
            RegExp(
                r'^(?:(?:hey|ok|okay) nomad[, ]+)?(?:please |(?:can|could|would) you (?:please )?)?'),
            '')
        .replaceFirst(RegExp(r'\s+(?:please|for me)[.!?]*$'), '')
        .replaceFirst(RegExp(r'[.!?]+$'), '')
        .trim();
    if (RegExp(
            r'^(?:stop|cancel|goodbye|bye|stop listening|end voice|exit voice|end conversation)$')
        .hasMatch(text)) {
      return const AssistantCommand('endVoice');
    }
    if (RegExp(
            r'^(?:what(?:\x27s| is) (?:the )?(?:time|current time)|what time is it|tell me the time)$')
        .hasMatch(text)) {
      return AssistantCommand.reply(
          "It's ${DateFormat.jm().format(now ?? DateTime.now())}.");
    }
    if (RegExp(
            r'^(?:what(?:\x27s| is) (?:the |today\x27s )?date|what (?:day|date) is (?:it|today)|what day is it today)$')
        .hasMatch(text)) {
      return AssistantCommand.reply(
          'Today is ${DateFormat.yMMMMEEEEd().format(now ?? DateTime.now())}.');
    }
    if (text == 'what can you do' || text == 'help me use voice') {
      return const AssistantCommand.reply(
          'I can answer questions, open apps, set timers and alarms, '
          'show directions, and open phone settings. Tap the middle button to interrupt me.');
    }

    final timer =
        RegExp(r'^(?:set|start)(?: a| the)? timer(?: for)?(?: (.+))?$')
            .firstMatch(text);
    if (timer != null) {
      final duration = timer[1];
      if (duration == null) return const AssistantCommand('timer');
      final seconds = _duration(duration);
      if (seconds == null) {
        return const AssistantCommand.reply(
            'Try saying set a timer for ten minutes, or for one hour and thirty minutes.');
      }
      return AssistantCommand('timer', {'seconds': seconds});
    }
    final alarm =
        RegExp(r'^(?:set|create)(?: an?| the)? alarm(?: for| at)?(?: (.+))?$')
            .firstMatch(text);
    if (alarm != null) {
      final time = (alarm[1] ?? '').replaceAll('.', '');
      final match = RegExp(
              r'^(\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)(?::(\d{2}))?\s*(am|pm)?$')
          .firstMatch(time);
      if (match == null) return const AssistantCommand('alarm');
      var hour = _number(match[1]!)?.toInt() ?? -1;
      final minute = int.tryParse(match[2] ?? '0') ?? -1;
      final period = match[3];
      if (minute < 0 ||
          minute > 59 ||
          hour < 0 ||
          hour > 23 ||
          (period != null && (hour < 1 || hour > 12))) {
        return const AssistantCommand.reply(
            'Please give a valid alarm time, such as seven thirty or 7:30 AM.');
      }
      if (period != null) hour = hour % 12 + (period == 'pm' ? 12 : 0);
      return AssistantCommand('alarm', {'hour': hour, 'minute': minute});
    }

    final directions = RegExp(
            r'^(?:navigate to|directions to|show directions to|take me to) (.+)$')
        .firstMatch(text);
    if (directions != null) {
      return AssistantCommand('directions', {'destination': directions[1]!});
    }
    final search = RegExp(
            r'^(?:search (?:the web )?for|search the web|google|look up) (.+)$')
        .firstMatch(text);
    if (search != null) {
      return AssistantCommand('webSearch', {'query': search[1]!});
    }
    final settings = RegExp(
            r'^(?:open |show |turn (?:on|off) )?(wi[ -]?fi|bluetooth|sound|display|battery|location|app|assistant)(?: settings| controls)?$')
        .firstMatch(text);
    if (settings != null) {
      return AssistantCommand(
          'settings', {'kind': settings[1]!.replaceAll(RegExp(r'[ -]'), '')});
    }
    final app = RegExp(r'^(?:open|launch) (.+)$').firstMatch(text);
    if (app != null && app[1]!.length <= 80) {
      return AssistantCommand('openApp',
          {'name': app[1]!.replaceFirst(RegExp(r' (?:app|application)$'), '')});
    }
    return null;
  }

  static int? _duration(String text) {
    final matches = RegExp(
            r'([a-z\d. -]+?)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b')
        .allMatches(text);
    double total = 0;
    var end = 0;
    for (final match in matches) {
      if (text.substring(end, match.start).trim().isNotEmpty) return null;
      final quantity = match[1]!.trim().replaceFirst(RegExp(r'^and\s+'), '');
      final value = _number(quantity);
      if (value == null || value <= 0) return null;
      final unit = match[2]!;
      total += value *
          (unit.startsWith('h')
              ? 3600
              : unit.startsWith('m')
                  ? 60
                  : 1);
      end = match.end;
    }
    if (end == 0 ||
        text.substring(end).trim().isNotEmpty ||
        total < 1 ||
        total > 86400) {
      return null;
    }
    return total.round();
  }

  static double? _number(String text) {
    final numeric = double.tryParse(text);
    if (numeric != null) return numeric.isFinite ? numeric : null;
    const values = {
      'a': 1,
      'an': 1,
      'one': 1,
      'two': 2,
      'three': 3,
      'four': 4,
      'five': 5,
      'six': 6,
      'seven': 7,
      'eight': 8,
      'nine': 9,
      'ten': 10,
      'eleven': 11,
      'twelve': 12,
      'thirteen': 13,
      'fourteen': 14,
      'fifteen': 15,
      'sixteen': 16,
      'seventeen': 17,
      'eighteen': 18,
      'nineteen': 19,
      'twenty': 20,
      'thirty': 30,
      'forty': 40,
      'fifty': 50,
      'sixty': 60,
      'seventy': 70,
      'eighty': 80,
      'ninety': 90,
    };
    if (text == 'half an' || text == 'half a') return 0.5;
    final parts = text.split(RegExp(r'[ -]+'));
    if (parts.length > 2 || parts.any((part) => !values.containsKey(part))) {
      return null;
    }
    if (parts.length == 2 &&
        (values[parts[0]]! < 20 || values[parts[1]]! >= 10)) {
      return null;
    }
    return parts.fold<double>(0, (sum, part) => sum + values[part]!);
  }
}
