import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/models/chat_session.dart';

void main() {
  group('ChatMessage', () {
    test('serializes and deserializes a user message', () {
      final msg = ChatMessage(
        text: 'Hello',
        fromUser: true,
        time: DateTime.utc(2026, 7, 31, 12, 0, 0),
        imagePaths: ['/tmp/a.png'],
        outputTokPerSec: 12.5,
        outputTokens: 250,
      );

      final restored = ChatMessage.fromJson(msg.toJson());

      expect(restored.text, 'Hello');
      expect(restored.fromUser, isTrue);
      expect(restored.time, msg.time);
      expect(restored.imagePaths, ['/tmp/a.png']);
      expect(restored.outputTokPerSec, 12.5);
      expect(restored.outputTokens, 250);
    });

    test('uses defaults for missing optional fields', () {
      final restored = ChatMessage.fromJson({
        'text': 'Hi',
        'fromUser': false,
        'time': '2026-07-31T00:00:00.000',
      });

      expect(restored.imagePaths, isEmpty);
      expect(restored.outputTokPerSec, 0);
      expect(restored.outputTokens, 0);
    });
  });

  group('ChatSession', () {
    test('serializes and deserializes a full conversation', () {
      final session = ChatSession(
        id: '123',
        title: 'Test chat',
        messages: [
          ChatMessage(text: 'Hi', fromUser: true, time: DateTime.utc(2026, 7, 31)),
          ChatMessage(
            text: 'Hello!',
            fromUser: false,
            time: DateTime.utc(2026, 7, 31),
          ),
        ],
        updatedAt: DateTime.utc(2026, 7, 31, 12, 30),
        modelId: 'nomad-lite-qwen-3.5-0.8b',
        projectId: 'p-1',
      );

      final restored = ChatSession.fromJson(session.toJson());

      expect(restored.id, '123');
      expect(restored.title, 'Test chat');
      expect(restored.messages, hasLength(2));
      expect(restored.messages.first.fromUser, isTrue);
      expect(restored.messages.last.text, 'Hello!');
      expect(restored.modelId, 'nomad-lite-qwen-3.5-0.8b');
      expect(restored.projectId, 'p-1');
      expect(restored.updatedAt, session.updatedAt);
    });

    test('round-trips an empty conversation', () {
      final session = ChatSession(
        id: 'empty',
        title: '',
        messages: [],
        updatedAt: DateTime.utc(2026, 7, 31),
      );

      final restored = ChatSession.fromJson(session.toJson());

      expect(restored.messages, isEmpty);
      expect(restored.modelId, isNull);
      expect(restored.projectId, isNull);
    });
  });
}
