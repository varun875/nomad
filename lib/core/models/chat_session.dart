
class ChatMessage {
  final String text;
  final bool fromUser;
  final DateTime time;
  final List<String> imagePaths;
  final double outputTokPerSec;
  final int outputTokens;

  ChatMessage({
    required this.text,
    required this.fromUser,
    required this.time,
    this.imagePaths = const [],
    this.outputTokPerSec = 0,
    this.outputTokens = 0,
  });

  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'fromUser': fromUser,
      'time': time.toIso8601String(),
      'imagePaths': imagePaths,
      'outputTokPerSec': outputTokPerSec,
      'outputTokens': outputTokens,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      text: json['text'] as String,
      fromUser: json['fromUser'] as bool,
      time: DateTime.parse(json['time'] as String),
      imagePaths: (json['imagePaths'] as List?)?.cast<String>() ?? [],
      outputTokPerSec: (json['outputTokPerSec'] as num?)?.toDouble() ?? 0,
      outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
    );
  }
}

class ChatSession {
  final String id;
  final String title;
  final List<ChatMessage> messages;
  final DateTime updatedAt;
  final String? modelId;
  final String? projectId;

  ChatSession({
    required this.id,
    required this.title,
    required this.messages,
    required this.updatedAt,
    this.modelId,
    this.projectId,
  });

  ChatSession copyWith({
    String? id,
    String? title,
    List<ChatMessage>? messages,
    DateTime? updatedAt,
    String? modelId,
    String? projectId,
  }) {
    return ChatSession(
      id: id ?? this.id,
      title: title ?? this.title,
      messages: messages ?? this.messages,
      updatedAt: updatedAt ?? this.updatedAt,
      modelId: modelId ?? this.modelId,
      projectId: projectId ?? this.projectId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'messages': messages.map((m) => m.toJson()).toList(),
      'updatedAt': updatedAt.toIso8601String(),
      'modelId': modelId,
      'projectId': projectId,
    };
  }

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] as String,
      title: json['title'] as String,
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      modelId: json['modelId'] as String?,
      projectId: json['projectId'] as String?,
    );
  }
}
