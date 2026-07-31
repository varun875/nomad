import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nomad/core/services/nomad_agent_service.dart';

void main() {
  late Directory root;
  late Directory outside;
  late NomadAgentService service;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nomad_agent_test_');
    outside = Directory.systemTemp.createTempSync('nomad_agent_outside_');
    service = NomadAgentService(projectPath: root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (outside.existsSync()) outside.deleteSync(recursive: true);
  });

  group('sandbox enforcement', () {
    Matcher sandboxError() => throwsA(
          predicate((e) => e.toString().contains('outside the project root')),
        );

    test('read_file rejects a relative path escaping the project root', () {
      expectLater(
        service.readFileTool.invoke({'path': '../secret.txt'}),
        sandboxError(),
      );
    });

    test('read_file rejects an absolute path outside the project root', () {
      final outsideFile = File('${outside.path}/secret.txt')
        ..writeAsStringSync('top secret');
      expectLater(
        service.readFileTool.invoke({'path': outsideFile.path}),
        sandboxError(),
      );
    });

    test('list_dir rejects a directory escape', () {
      expectLater(
        service.listDirTool.invoke({'path': '..'}),
        sandboxError(),
      );
    });

    test('write_file refuses to create a file outside the sandbox', () {
      expectLater(
        service.writeFileTool.invoke({
          'path': '../pwned.txt',
          'content': 'evil',
        }),
        sandboxError(),
      );
      expect(File('${root.parent.path}/pwned.txt').existsSync(), isFalse);
    });

    test('write_file refuses absolute paths outside the sandbox', () {
      final target = '${outside.path}/pwned.txt';
      expectLater(
        service.writeFileTool.invoke({
          'path': target,
          'content': 'evil',
        }),
        sandboxError(),
      );
      expect(File(target).existsSync(), isFalse);
    });
  });

  group('in-sandbox operations', () {
    test('write_file creates parent directories and writes content', () async {
      final result = await service.writeFileTool.invoke({
        'path': 'src/lib/util.dart',
        'content': 'void main() {}',
      });
      expect(result.toString(), contains('Wrote'));
      final written = File('${root.path}/src/lib/util.dart');
      expect(written.existsSync(), isTrue);
      expect(written.readAsStringSync(), 'void main() {}');
    });

    test('read_file returns line-numbered contents', () async {
      File('${root.path}/hello.txt').writeAsStringSync('alpha\nbeta');
      final result = await service.readFileTool.invoke({'path': 'hello.txt'});
      expect(result.toString(), contains('  1: alpha'));
      expect(result.toString(), contains('  2: beta'));
    });

    test('read_file reports a missing file as an error string', () async {
      final result =
          await service.readFileTool.invoke({'path': 'nope.txt'});
      expect(result.toString(), contains('file not found'));
    });

    test('list_dir lists entries and skips hidden and build folders', () async {
      Directory('${root.path}/lib').createSync(recursive: true);
      File('${root.path}/lib/a.dart').writeAsStringSync('a');
      Directory('${root.path}/build').createSync();
      File('${root.path}/.hidden').writeAsStringSync('x');

      final result = await service.listDirTool.invoke({'path': '.'});
      final text = result.toString();
      expect(text, contains('lib/'));
      expect(text, isNot(contains('build')));
      expect(text, isNot(contains('.hidden')));
    });
  });
}
