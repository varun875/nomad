// Run from server/: dart --disable-dart-dev test/nomad_code_server_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _apiKey = 'nomad-server-regression-test-key';
const _origin = 'http://localhost:3210';
const _timeout = Duration(seconds: 10);

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final serverDirectory = File.fromUri(Platform.script).parent.parent;
  final temporary = await Directory.systemTemp.createTemp('nomad-code-test-');
  // Keep both current and legacy model discovery inside the temporary tree.
  final models = Directory.fromUri(temporary.uri.resolve('Nomad/models/'));
  final client = HttpClient()..connectionTimeout = _timeout;
  final log = StringBuffer();
  Process? server;
  StreamSubscription<String>? stdoutSubscription;
  StreamSubscription<String>? stderrSubscription;
  var passed = 0;
  try {
    await models.create(recursive: true);
    server = await Process.start(
      Platform.resolvedExecutable,
      [
        // Run the VM directly without building or downloading native assets.
        '--disable-dart-dev',
        '--packages=${serverDirectory.uri.resolve('.dart_tool/package_config.json').toFilePath()}',
        serverDirectory.uri.resolve('bin/nomad_code_server.dart').toFilePath(),
        '--host',
        '127.0.0.1',
        '--port',
        '0',
        '--models-dir',
        models.path,
      ],
      workingDirectory: serverDirectory.path,
      environment: {'NOMAD_API_KEY': _apiKey, 'NOMAD_ALLOWED_ORIGIN': _origin},
    );
    final listening = Completer<Uri>();
    stdoutSubscription = server.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          log.writeln(line);
          const prefix = 'Nomad Code API listening at ';
          if (line.startsWith(prefix) && !listening.isCompleted) {
            listening.complete(Uri.parse(line.substring(prefix.length)));
          }
        });
    stderrSubscription = server.stderr
        .transform(utf8.decoder)
        .listen(log.write);
    server.exitCode.then((code) {
      if (!listening.isCompleted) {
        listening.completeError(StateError('Server exited with code $code.'));
      }
    });
    final base = await listening.future.timeout(_timeout);

    Future<({int status, String body, HttpHeaders headers})> request(
      String method,
      String path, {
      List<int>? body,
      String? authorization = 'Bearer $_apiKey',
      Map<String, Object> headers = const {},
    }) async {
      final outgoing = await client.openUrl(method, base.resolve(path));
      if (authorization != null) {
        outgoing.headers.set(HttpHeaders.authorizationHeader, authorization);
      }
      headers.forEach((name, value) {
        outgoing.headers.set(name, value);
        outgoing.headers.noFolding(name);
      });
      if (body != null) {
        outgoing.headers.contentType = ContentType.json;
        outgoing.add(body);
      }
      final response = await outgoing.close().timeout(_timeout);
      return (
        status: response.statusCode,
        body: await utf8.decoder.bind(response).join().timeout(_timeout),
        headers: response.headers,
      );
    }

    Future<void> checkAlive() async {
      final health = await request('GET', '/health', authorization: null);
      _expect(
        health.status == 200 && health.body == '{"status":"ok"}',
        'Subsequent unauthenticated health request failed: $health',
      );
      final available = await request('GET', '/v1/models');
      _expect(
        available.status == 200 &&
            available.body == '{"object":"list","data":[]}',
        'Subsequent authenticated models request failed: $available',
      );
    }

    Future<void> expectError(
      String name,
      List<int> body,
      int status,
      String message, {
      String? authorization = 'Bearer $_apiKey',
      Map<String, Object> headers = const {},
    }) async {
      final response = await request(
        'POST',
        '/v1/chat/completions',
        body: body,
        authorization: authorization,
        headers: headers,
      );
      _expect(
        response.status == status,
        '$name: expected HTTP $status, got ${response.status}: ${response.body}',
      );
      _expect(
        response.headers.contentType?.mimeType == 'application/json',
        '$name: expected a JSON error response.',
      );
      // Exact public error envelopes also rule out leaked paths or stack traces.
      _expect(
        response.body ==
            jsonEncode({
              'error': {'message': message, 'type': 'nomad_error'},
            }),
        '$name: unexpected error response: ${response.body}',
      );
      await checkAlive();
      stdout.writeln('PASS: $name');
      passed++;
    }

    await checkAlive();
    await expectError(
      'authenticated numeric model',
      utf8.encode('{"model":123}'),
      400,
      'model must be a non-empty string.',
    );

    for (final authorization in <String?>[null, 'Bearer wrong-key']) {
      await expectError(
        'authentication precedes validation ($authorization)',
        utf8.encode('{"model":123}'),
        401,
        'Invalid API key.',
        authorization: authorization,
      );
      final response = await request(
        'GET',
        '/v1/models',
        authorization: authorization,
      );
      _expect(response.status == 401, 'Models must require a valid API key.');
    }

    for (final body in ['', '{', '[]', 'null', '123', '"text"']) {
      await expectError(
        'invalid JSON object: $body',
        utf8.encode(body),
        400,
        'Request body must be a JSON object.',
      );
    }
    await expectError(
      'invalid UTF-8',
      [0xff],
      400,
      'Request body must be a JSON object.',
    );

    const valid = <String, Object?>{
      'model': 'nomad-lite-qwen-3.5-0.8b',
      'messages': [
        {'role': 'user', 'content': 'Hello'},
      ],
    };
    final invalidFields = <String, (List<Object?>, String)>{
      'model': (
        [null, true, [], {}, '', '   '],
        'model must be a non-empty string.',
      ),
      'messages': (
        [null, 'text', [], {}],
        'messages must be a non-empty array.',
      ),
      'temperature': (
        ['hot', true, [], {}],
        'temperature must be a finite number.',
      ),
      'max_tokens': (
        ['many', true, [], {}, 0, -1, 1.5],
        'max_tokens must be a positive integer.',
      ),
      'stop': (
        [
          123,
          true,
          {},
          ['end', 1],
          [null],
        ],
        'stop must be a string or an array of strings.',
      ),
      'stream': (['true', 1, [], {}], 'stream must be a boolean.'),
    };
    for (final entry in invalidFields.entries) {
      for (final value in entry.value.$1) {
        await expectError(
          'invalid ${entry.key}: ${jsonEncode(value)}',
          utf8.encode(jsonEncode({...valid, entry.key: value})),
          400,
          entry.value.$2,
        );
      }
    }
    for (final field in ['model', 'messages']) {
      final payload = {...valid}..remove(field);
      await expectError(
        'missing $field',
        utf8.encode(jsonEncode(payload)),
        400,
        invalidFields[field]!.$2,
      );
    }
    for (final message in <Object?>[
      null,
      'text',
      [],
      {},
      {'role': 123, 'content': 'Hello'},
      {'role': 'unknown', 'content': 'Hello'},
      {'role': 'user'},
      {'role': 'user', 'content': 123},
      {'role': 'user', 'content': []},
    ]) {
      await expectError(
        'invalid message: ${jsonEncode(message)}',
        utf8.encode(
          jsonEncode({
            ...valid,
            'messages': [message],
          }),
        ),
        400,
        'Invalid messages array.',
      );
    }
    for (final field in ['temperature', 'max_tokens']) {
      final body =
          '${jsonEncode(valid).substring(0, jsonEncode(valid).length - 1)},"$field":1e999}';
      await expectError(
        'non-finite $field',
        utf8.encode(body),
        400,
        invalidFields[field]!.$2,
      );
    }

    // Valid requests reach discovery, but an empty model directory prevents any
    // native engine allocation or model loading during these regressions.
    for (final options in <Map<String, Object?>>[
      {},
      {'temperature': null, 'max_tokens': null, 'stop': null, 'stream': null},
      {'temperature': 0, 'max_tokens': 1, 'stop': 'end', 'stream': true},
      {
        'temperature': 0.5,
        'max_tokens': 12.0,
        'stop': ['end'],
        'stream': false,
      },
    ]) {
      await expectError(
        'valid options: ${jsonEncode(options)}',
        utf8.encode(jsonEncode({...valid, ...options})),
        404,
        'Model is not available. Check GET /v1/models.',
      );
    }

    // Multiple Origin values make HttpHeaders.value throw inside _handle,
    // independently of the JSON validation path.
    await expectError(
      'unexpected handler error is contained',
      utf8.encode(jsonEncode(valid)),
      500,
      'Internal server error.',
      headers: {
        'origin': ['http://first.invalid', 'http://second.invalid'],
      },
    );

    final preflight = await request(
      'OPTIONS',
      '/v1/chat/completions',
      authorization: null,
      headers: {'origin': _origin},
    );
    _expect(
      preflight.status == 204 &&
          preflight.headers.value('access-control-allow-origin') == _origin,
      'Configured CORS preflight must remain available without authentication.',
    );
    final untrusted = await request(
      'GET',
      '/health',
      headers: {'origin': 'http://untrusted.invalid'},
    );
    _expect(
      untrusted.headers.value('access-control-allow-origin') == null,
      'Untrusted origins must not receive CORS permission.',
    );
    passed++;
    stdout.writeln('PASS: CORS behavior');

    for (final completeBody in [false, true]) {
      final socket = await Socket.connect(
        '127.0.0.1',
        base.port,
      ).timeout(_timeout);
      socket.done.ignore();
      final drained = socket.drain<void>().catchError((Object _) {});
      try {
        final body = completeBody ? '{"model":123}' : '{"model":';
        socket.write(
          'POST /v1/chat/completions HTTP/1.1\r\n'
          'Host: 127.0.0.1:${base.port}\r\n'
          'Authorization: Bearer $_apiKey\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: ${completeBody ? body.length : 100}\r\n'
          'Connection: close\r\n\r\n$body',
        );
        await socket.flush();
        if (!completeBody) {
          // Half-close to deliver the partial body and EOF in order. For the
          // complete body, disconnect immediately without waiting for a response.
          await socket.close();
          await drained.timeout(_timeout);
        }
      } finally {
        socket.destroy();
        await drained.timeout(_timeout);
      }
      await checkAlive();
      passed++;
      stdout.writeln(
        'PASS: disconnected client (complete body: $completeBody)',
      );
    }
    stdout.writeln('All $passed HTTP regressions passed.');
  } catch (_) {
    stderr.writeln('Server output:\n$log');
    rethrow;
  } finally {
    client.close(force: true);
    if (server != null) {
      server.kill();
      await server.exitCode.timeout(_timeout);
    }
    await stdoutSubscription?.cancel();
    await stderrSubscription?.cancel();
    await temporary.delete(recursive: true);
  }
}
