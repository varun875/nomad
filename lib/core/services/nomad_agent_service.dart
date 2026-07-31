import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart' hide ChatSession;
import 'package:path/path.dart' as p;

/// Toolset that gives the Nomad Code agent access to a user's project
/// directory: read/write files, list directories, search, and run shell
/// commands. All operations are sandboxed to the project root.
class NomadAgentService {
  final String projectPath;

  NomadAgentService({required this.projectPath});

  /// Resolve a (possibly relative) path against the project root and
  /// reject any path that escapes the sandbox.
  String _resolve(String input) {
    final raw = input.trim();
    final abs = p.isAbsolute(raw) ? raw : p.join(projectPath, raw);
    final norm = p.normalize(abs);
    final root = p.normalize(projectPath);
    if (!p.isWithin(root, norm) && norm != root) {
      throw Exception(
          'Path "$input" is outside the project root and cannot be accessed.');
    }
    return norm;
  }

  String _relative(String absPath) =>
      p.relative(absPath, from: projectPath).replaceAll('\\', '/');

  // =========================================================================
  // Tool definitions
  // =========================================================================

  List<ToolDefinition> get tools => [
        readFileTool,
        writeFileTool,
        listDirTool,
        searchTool,
        runCommandTool,
      ];

  ToolDefinition get readFileTool => ToolDefinition(
        name: 'read_file',
        description:
            'Read the contents of a text file in the project. Use a path '
            'relative to the project root (e.g. "lib/main.dart"). Returns '
            'the file contents prefixed with line numbers.',
        parameters: [
          ToolParam.string('path',
              description: 'Project-relative path to the file.',
              required: true),
        ],
        handler: (params) async {
          final path = params.getRequiredString('path');
          final abs = _resolve(path);
          final f = File(abs);
          if (!f.existsSync()) return 'Error: file not found: $path';
          try {
            final content = await f.readAsString();
            final lines = const LineSplitter().convert(content);
            const maxLines = 800;
            final shown = lines.take(maxLines).toList();
            final buf = StringBuffer();
            for (var i = 0; i < shown.length; i++) {
              buf.writeln('${(i + 1).toString().padLeft(4)}: ${shown[i]}');
            }
            if (lines.length > maxLines) {
              buf.writeln(
                  '... (${lines.length - maxLines} more lines truncated)');
            }
            return buf.toString();
          } catch (e) {
            return 'Error reading file: $e';
          }
        },
      );

  ToolDefinition get writeFileTool => ToolDefinition(
        name: 'write_file',
        description:
            'Create or overwrite a text file in the project with the given '
            'contents. Use a project-relative path. Parent directories are '
            'created automatically.',
        parameters: [
          ToolParam.string('path',
              description: 'Project-relative path to the file.',
              required: true),
          ToolParam.string('content',
              description: 'The full contents to write to the file.',
              required: true),
        ],
        handler: (params) async {
          final path = params.getRequiredString('path');
          final content = params.getRequiredString('content');
          final abs = _resolve(path);
          try {
            final f = File(abs);
            await f.parent.create(recursive: true);
            await f.writeAsString(content);
            final bytes = content.length;
            return 'Wrote ${_relative(abs)} ($bytes bytes).';
          } catch (e) {
            return 'Error writing file: $e';
          }
        },
      );

  ToolDefinition get listDirTool => ToolDefinition(
        name: 'list_dir',
        description:
            'List files and subdirectories at a path inside the project. '
            'Pass "." for the project root. Hidden files (.) and common '
            'build/vendor folders are skipped.',
        parameters: [
          ToolParam.string('path',
              description: 'Project-relative directory path. Use "." for root.',
              required: true),
        ],
        handler: (params) async {
          final path = params.getRequiredString('path');
          final abs = _resolve(path);
          final dir = Directory(abs);
          if (!dir.existsSync()) return 'Error: directory not found: $path';
          try {
            final entries = await dir.list(followLinks: false).toList();
            entries.sort((a, b) => a.path.compareTo(b.path));
            final buf = StringBuffer();
            const skip = {
              '.git',
              '.dart_tool',
              'build',
              'node_modules',
              '.venv',
              '__pycache__',
              '.idea',
              '.gradle',
            };
            for (final e in entries) {
              final name = p.basename(e.path);
              if (skip.contains(name)) continue;
              if (name.startsWith('.')) continue;
              final isDir = e is Directory;
              buf.writeln(isDir ? '$name/' : name);
            }
            final out = buf.toString();
            return out.isEmpty ? '(empty)' : out;
          } catch (e) {
            return 'Error listing directory: $e';
          }
        },
      );

  ToolDefinition get searchTool => ToolDefinition(
        name: 'search',
        description:
            'Search for a substring across all text files in the project. '
            'Returns matching file paths with line numbers and the matching '
            'lines. Use this to find symbols, identifiers, or text quickly.',
        parameters: [
          ToolParam.string('query',
              description: 'Text to search for (case-sensitive).',
              required: true),
        ],
        handler: (params) async {
          final query = params.getRequiredString('query');
          if (query.isEmpty) return 'Error: empty query';
          try {
            final root = Directory(projectPath);
            final buf = StringBuffer();
            int matchCount = 0;
            const maxMatches = 80;
            const skip = {
              '.git',
              '.dart_tool',
              'build',
              'node_modules',
              '.venv',
              '__pycache__',
              '.idea',
              '.gradle',
            };
            await for (final entity
                in root.list(recursive: true, followLinks: false)) {
              if (entity is! File) continue;
              final segs = p.split(p.relative(entity.path, from: projectPath));
              if (segs.any(skip.contains)) continue;
              if (segs.any((s) => s.startsWith('.'))) continue;
              final size = await entity.length();
              if (size > 1024 * 1024) continue; // skip files > 1MB
              try {
                final content = await entity.readAsString();
                final lines = const LineSplitter().convert(content);
                for (var i = 0; i < lines.length; i++) {
                  if (lines[i].contains(query)) {
                    buf.writeln(
                        '${_relative(entity.path)}:${i + 1}: ${lines[i].trim()}');
                    matchCount++;
                    if (matchCount >= maxMatches) {
                      buf.writeln(
                          '... (results truncated at $maxMatches matches)');
                      return buf.toString();
                    }
                  }
                }
              } catch (_) {
                // Skip binary / unreadable files
              }
            }
            if (matchCount == 0) return 'No matches for "$query".';
            return buf.toString();
          } catch (e) {
            return 'Error during search: $e';
          }
        },
      );

  ToolDefinition get runCommandTool => ToolDefinition(
        name: 'run_command',
        description:
            'Run a shell command in the project root and return its '
            'combined stdout/stderr. The command runs through the system '
            'shell with a 60-second timeout. Use this to build, test, '
            'inspect git, or run scripts.',
        parameters: [
          ToolParam.string('command',
              description:
                  'The shell command to execute (e.g. "ls -la", "git status").',
              required: true),
        ],
        handler: (params) async {
          final command = params.getRequiredString('command').trim();
          if (command.isEmpty) return 'Error: empty command';
          return _runShell(command, cwd: projectPath);
        },
      );

  static Future<String> _runShell(String command, {required String cwd}) async {
    try {
      final isWindows = Platform.isWindows;
      final shell = isWindows ? 'cmd' : '/bin/sh';
      final args = isWindows ? ['/C', command] : ['-c', command];
      final proc = await Process.start(
        shell,
        args,
        workingDirectory: cwd,
        runInShell: false,
      );
      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      final stdoutSub = proc.stdout
          .transform(utf8.decoder)
          .listen((d) => stdoutBuf.write(d));
      final stderrSub = proc.stderr
          .transform(utf8.decoder)
          .listen((d) => stderrBuf.write(d));

      int? exitCode;
      try {
        exitCode = await proc.exitCode.timeout(const Duration(seconds: 60));
      } on TimeoutException {
        proc.kill(ProcessSignal.sigkill);
        await stdoutSub.cancel();
        await stderrSub.cancel();
        return 'Error: command timed out after 60s.\n'
            'stdout:\n${_truncate(stdoutBuf.toString())}\n'
            'stderr:\n${_truncate(stderrBuf.toString())}';
      }
      await stdoutSub.asFuture<void>();
      await stderrSub.asFuture<void>();

      final out = _truncate(stdoutBuf.toString());
      final err = _truncate(stderrBuf.toString());
      final buf = StringBuffer()..writeln('exit: $exitCode');
      if (out.isNotEmpty) buf.writeln('stdout:\n$out');
      if (err.isNotEmpty) buf.writeln('stderr:\n$err');
      return buf.toString();
    } catch (e) {
      return 'Error running command: $e';
    }
  }

  static String _truncate(String s, {int max = 8000}) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}\n... (truncated, ${s.length - max} more chars)';
  }
}
