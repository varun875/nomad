import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/utils/assistant_command.dart';

void main() {
  test('common phone requests are handled without a language model', () {
    expect(
        AssistantCommand.parse('Could you please open YouTube for me?')
            ?.arguments,
        {'name': 'youtube'});
    expect(
        AssistantCommand.parse('Navigate to the nearest pharmacy')?.arguments,
        {'destination': 'the nearest pharmacy'});
    expect(AssistantCommand.parse('Open Wi-Fi settings')?.arguments,
        {'kind': 'wifi'});
    expect(AssistantCommand.parse('Turn off Bluetooth')?.arguments,
        {'kind': 'bluetooth'});
    expect(AssistantCommand.parse('Google Flutter documentation')?.arguments,
        {'query': 'flutter documentation'});
    expect(AssistantCommand.parse('Stop listening')?.action, 'endVoice');
  });

  test('discussing or quoting actions does not run a phone action', () {
    for (final text in [
      'How do I open YouTube?',
      'Write a story about setting a timer',
      'Explain the phrase open settings',
      'Do not open YouTube',
      'Tell me a joke'
    ]) {
      expect(AssistantCommand.parse(text), isNull, reason: text);
    }
  });

  test('timers understand spoken numbers, fractions and compound durations',
      () {
    expect(AssistantCommand.parse('Set a timer for ten minutes')?.arguments,
        {'seconds': 600});
    expect(
        AssistantCommand.parse('Start a timer for one hour and thirty minutes')
            ?.arguments,
        {'seconds': 5400});
    expect(AssistantCommand.parse('Set a timer for 1.5 minutes')?.arguments,
        {'seconds': 90});
    expect(AssistantCommand.parse('Set a timer for half an hour')?.arguments,
        {'seconds': 1800});
    expect(
        AssistantCommand.parse('Set a timer for twenty-five seconds')
            ?.arguments,
        {'seconds': 25});
    expect(AssistantCommand.parse('Set a timer')?.arguments, isEmpty);
  });

  test('invalid timer durations are explained rather than sent to Android', () {
    for (final duration in [
      '-1 seconds',
      '0 minutes',
      '999999 hours',
      'ten minutes then call Bob'
    ]) {
      expect(
          AssistantCommand.parse('Set a timer for $duration')?.action, 'reply');
    }
  });

  test('alarms convert AM/PM correctly and reject invalid times', () {
    expect(AssistantCommand.parse('Set an alarm for 7:30 PM')?.arguments,
        {'hour': 19, 'minute': 30});
    expect(AssistantCommand.parse('Set an alarm at 12 AM')?.arguments,
        {'hour': 0, 'minute': 0});
    expect(AssistantCommand.parse('Set an alarm for seven am')?.arguments,
        {'hour': 7, 'minute': 0});
    expect(AssistantCommand.parse('Set an alarm for 7:90')?.action, 'reply');
    expect(
        AssistantCommand.parse('Set an alarm for tomorrow morning')?.arguments,
        isEmpty);
  });

  test('time and date are grounded in the device clock', () {
    final now = DateTime(2026, 10, 25, 15, 42);
    expect(AssistantCommand.parse('What time is it?', now: now)?.response,
        contains('3:42'));
    expect(AssistantCommand.parse("What's today's date?", now: now)?.response,
        contains('2026'));
  });
}
