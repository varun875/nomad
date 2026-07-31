import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:llamadart/llamadart.dart';

class Memory {
  final String id;
  final String content;
  final DateTime createdAt;
  final String category; // e.g., 'preference', 'fact', 'biography'

  Memory({
    required this.id,
    required this.content,
    required this.createdAt,
    this.category = 'general',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'category': category,
  };

  factory Memory.fromJson(Map<String, dynamic> json) => Memory(
    id: json['id'] as String,
    content: json['content'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    category: json['category'] as String? ?? 'general',
  );
}

class MemoryService {
  static final MemoryService _instance = MemoryService._internal();
  factory MemoryService() => _instance;
  MemoryService._internal();

  static const String _boxName = 'memories';

  Future<void> init() async {
    await Hive.openBox(_boxName);
  }

  List<Memory> getAllMemories() {
    final box = Hive.box(_boxName);
    return box.values
        .map((v) => Memory.fromJson(Map<String, dynamic>.from(v)))
        .toList();
  }

  Future<void> saveMemory(String content, {String category = 'general'}) async {
    final box = Hive.box(_boxName);
    final id = const Uuid().v4();
    final memory = Memory(
      id: id,
      content: content,
      createdAt: DateTime.now(),
      category: category,
    );
    await box.put(id, memory.toJson());
  }

  Future<void> deleteMemory(String id) async {
    final box = Hive.box(_boxName);
    await box.delete(id);
  }

  String getMemoriesForPrompt() {
    final memories = getAllMemories();
    if (memories.isEmpty) return "";
    
    final buffer = StringBuffer("\n\nUser Context (what you know about the user):\n");
    for (final m in memories) {
      buffer.writeln("- ${m.content}");
    }
    return buffer.toString();
  }

  static final ToolDefinition saveMemoryTool = ToolDefinition(
    name: 'save_memory',
    description: 'Save information about the user (preferences, facts, biography) to remember in future conversations.',
    parameters: [
      ToolParam.string('content',
          description: 'The fact or preference to remember about the user.', required: true),
      ToolParam.string('category',
          description: 'The category of the memory (preference, fact, biography, general).',
          required: false),
    ],
    handler: (params) async {
      final content = params.getRequiredString('content');
      final category = params.getString('category') ?? 'general';
      await MemoryService().saveMemory(content, category: category);
      return 'Memory saved successfully: $content';
    },
  );
}
