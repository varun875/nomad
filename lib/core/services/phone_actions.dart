import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';

import '../utils/assistant_command.dart';
import 'assistant_platform_service.dart';

/// Outcome of a device action, with wording that is safe to show or speak.
class PhoneActionResult {
  const PhoneActionResult(this.success, this.message);

  final bool success;
  final String message;
}

/// Runs Nomad's phone actions through the Android assistant channel.
///
/// Voice and typed chat share this one path, so "set a timer for ten minutes"
/// behaves the same whether it was spoken or typed, and the model can request
/// the same actions through [tool] when the phrasing is its own.
class PhoneActions {
  const PhoneActions(this.platform);

  final AssistantPlatformService platform;

  /// Every action this layer will forward. Kept in sync with
  /// `AssistantActions.kt`, which is the only place that touches the OS.
  static const actions = <String>[
    'openApp',
    'settings',
    'timer',
    'alarm',
    'directions',
    'webSearch',
    'openUrl',
    'call',
    'message',
    'mediaPlay',
    'mediaPause',
    'mediaNext',
    'mediaPrevious',
    'volumeUp',
    'volumeDown',
    'volumeMute',
    'volumeUnmute',
    'battery',
  ];

  Future<PhoneActionResult> execute(
    String action,
    Map<String, Object> arguments,
  ) async {
    if (!actions.contains(action)) {
      return const PhoneActionResult(
        false,
        'That phone action is not available.',
      );
    }
    try {
      final result = await platform.executeAction(action, arguments);
      final success = result['success'] == true;
      final message = (result['message'] as String?)?.trim() ?? '';
      return PhoneActionResult(
        success,
        message.isNotEmpty
            ? message
            : success
            ? 'Done.'
            : 'Your phone could not run that action.',
      );
    } on MissingPluginException {
      return const PhoneActionResult(
        false,
        'Phone actions are available in the Android app.',
      );
    } on PlatformException catch (error) {
      return PhoneActionResult(
        false,
        error.message ?? 'Your phone could not run that action.',
      );
    }
  }

  /// Runs a command that [AssistantCommand] already understood.
  Future<PhoneActionResult> run(AssistantCommand command) =>
      execute(command.action, command.arguments);

  /// Tool the language model can call for requests the fast parser does not
  /// cover, such as "put on some music" or "how much battery is left".
  ToolDefinition get tool => ToolDefinition(
    name: 'phone_action',
    description:
        'Run an action on the user\'s phone: open an app, change a '
        'phone setting, set a timer or alarm, show directions, dial or '
        'text a number, control music and volume, check the battery, open '
        'a web page, or search the web in the browser. Use this whenever '
        'the user asks you to do something on the device instead of only '
        'talking about it.',
    parameters: [
      ToolParam.enumType(
        'action',
        values: actions,
        required: true,
        description: 'The device action to run.',
      ),
      ToolParam.string(
        'name',
        description: 'App name for openApp, for example "youtube".',
      ),
      ToolParam.string(
        'kind',
        description:
            'Settings screen for settings: wifi, bluetooth, '
            'sound, speech, display, battery, location, or app.',
      ),
      ToolParam.integer(
        'seconds',
        description: 'Timer length in seconds for timer (1-86400).',
      ),
      ToolParam.integer('hour', description: 'Alarm hour (0-23).'),
      ToolParam.integer('minute', description: 'Alarm minute (0-59).'),
      ToolParam.string(
        'destination',
        description: 'Place or address for directions.',
      ),
      ToolParam.string('query', description: 'Search text for webSearch.'),
      ToolParam.string('url', description: 'Web address for openUrl.'),
      ToolParam.string(
        'number',
        description: 'Phone number for call or message.',
      ),
      ToolParam.string(
        'body',
        description: 'Message text for message, when the user dictated it.',
      ),
    ],
    handler: (params) async {
      final action = params.getRequiredString('action');
      final arguments = <String, Object>{};
      for (final key in const [
        'name',
        'kind',
        'destination',
        'query',
        'url',
        'number',
        'body',
      ]) {
        final value = params.raw[key];
        if (value is String && value.trim().isNotEmpty) {
          arguments[key] = value.trim();
        }
      }
      for (final key in const ['seconds', 'hour', 'minute']) {
        final value = params.raw[key];
        if (value is num) arguments[key] = value.toInt();
      }
      final result = await execute(action, arguments);
      return result.message;
    },
  );
}
