import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

const _modelNames = <String, String>{
  'nomad-lite-qwen-3.5-0.8b': 'Nomad Lite',
  'nomad-omni-lfm3-2b': 'Nomad Omni',
  'nomad-steady-lfm3-2b': 'Nomad Steady',
  'nomad-smart-gemma4-e4b': 'Nomad Smart',
  'nomad-pro-mimo26-9b': 'Nomad Pro',
};

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final host = options['host'] ?? '127.0.0.1';
  final port = int.tryParse(options['port'] ?? '8787') ?? 8787;

  // Auth is required even on localhost: any local process - or any website via
  // the user's browser - can otherwise POST to the server and drive the model.
  final apiKey = Platform.environment['NOMAD_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln(
        'Set NOMAD_API_KEY before starting the server. Without it any local '
        'process, or any website open in the browser, could call the model.');
    exitCode = 2;
    return;
  }

  // Optional browser origin allowed to make cross-origin requests. When unset
  // no Access-Control-Allow-* headers are sent, so browsers block cross-origin
  // calls to the API (non-browser clients are unaffected).
  final allowedOrigin = Platform.environment['NOMAD_ALLOWED_ORIGIN'];

  final modelDir = Directory(options['models-dir'] ?? _defaultModelsDirectory());
  await modelDir.create(recursive: true);
  final server = await HttpServer.bind(host, port);
  stdout.writeln(
      'Nomad Code API listening at http://${server.address.address}:${server.port}/v1');
  stdout.writeln('Models directory: ${modelDir.path}');
  await for (final request in server) {
    // Native model contexts can consume several gigabytes; process one
    // completion at a time so clients cannot accidentally OOM the host.
    // A disconnect can fail response.done before close() is awaited.
    request.response.done.ignore();
    try {
      await _handle(request, modelDir, apiKey, allowedOrigin);
    } catch (error) {
      stderr.writeln('Request failed: $error');
      try {
        await _error(request.response, HttpStatus.internalServerError,
            'Internal server error.');
      } catch (_) {
        // Headers may already be sent, or the client may be disconnected.
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--') && i + 1 < args.length) {
      result[arg.substring(2)] = args[++i];
    }
  }
  return result;
}

String _defaultModelsDirectory() {
  final home = Platform.isWindows
      ? (Platform.environment['USERPROFILE'] ?? '.')
      : (Platform.environment['HOME'] ?? '.');
  return '$home${Platform.pathSeparator}Documents${Platform.pathSeparator}Nomad${Platform.pathSeparator}models';
}

Future<List<_AvailableModel>> _availableModels(Directory dir) async {
  final result = <_AvailableModel>[];
  for (final entry in _modelNames.entries) {
    final filename = '${entry.key}.gguf';
    var file = File('${dir.path}${Platform.pathSeparator}$filename');
    // Existing app installs used Documents/models before the shared folder was
    // introduced. Continue to discover those downloads without moving them.
    if (!await file.exists()) {
      final legacy = File('${dir.parent.parent.path}${Platform.pathSeparator}models${Platform.pathSeparator}$filename');
      if (await legacy.exists()) file = legacy;
    }
    if (await file.exists()) result.add(_AvailableModel(entry.key, entry.value, file.path));
  }
  return result;
}

/// Compares two strings without early-exiting on the first differing byte, so
/// the API key cannot be recovered via response timing.
bool _constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  if (x.length != y.length) return false;
  var diff = 0;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

Future<void> _handle(HttpRequest request, Directory modelDir, String apiKey,
    String? allowedOrigin) async {
  request.response.headers
      .set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');

  // Only echo CORS headers for the single configured origin. Defaults to none,
  // so a random website cannot read responses from (or drive) the server.
  final origin = request.headers.value('origin');
  if (allowedOrigin != null &&
      allowedOrigin.isNotEmpty &&
      origin != null &&
      origin == allowedOrigin) {
    request.response.headers
      ..set('access-control-allow-origin', allowedOrigin)
      ..set('access-control-allow-headers', 'Authorization, Content-Type')
      ..set('access-control-allow-methods', 'GET, POST, OPTIONS')
      ..set('vary', 'Origin');
  }

  if (request.method == 'OPTIONS') {
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    return;
  }

  // Health is the only unauthenticated endpoint; everything else requires the
  // bearer token, including requests from localhost.
  if (request.uri.path != '/health') {
    final authorization = request.headers.value(HttpHeaders.authorizationHeader);
    if (authorization == null ||
        !_constantTimeEquals(authorization, 'Bearer $apiKey')) {
      await _error(request.response, HttpStatus.unauthorized, 'Invalid API key.');
      return;
    }
  }

  if (request.uri.path == '/health' && request.method == 'GET') {
    request.response.write(jsonEncode({'status': 'ok'}));
  } else if (request.uri.path == '/v1/models' && request.method == 'GET') {
    final models = await _availableModels(modelDir);
    request.response.write(jsonEncode({
      'object': 'list',
      'data': [for (final model in models) {'id': model.id, 'object': 'model', 'created': 0, 'owned_by': 'nomad', 'name': model.name}],
    }));
  } else if (request.uri.path == '/v1/chat/completions' && request.method == 'POST') {
    await _chatCompletion(request, modelDir);
  } else {
    await _error(request.response, HttpStatus.notFound, 'Unknown endpoint.');
    return;
  }
  await request.response.close();
}

Future<void> _chatCompletion(HttpRequest request, Directory modelDir) async {
  final Map<String, dynamic> json;
  try {
    // Decode after draining the body so invalid UTF-8 cannot cancel the socket.
    final body = await request.fold(BytesBuilder(copy: false),
        (bytes, chunk) => bytes..add(chunk));
    final decoded = jsonDecode(utf8.decode(body.takeBytes()));
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    json = decoded;
  } on FormatException {
    await _error(request.response, HttpStatus.badRequest, 'Request body must be a JSON object.');
    return;
  }
  final modelId = json['model'];
  if (modelId is! String || modelId.trim().isEmpty) {
    await _error(request.response, HttpStatus.badRequest, 'model must be a non-empty string.');
    return;
  }
  final rawMessages = json['messages'];
  if (rawMessages is! List || rawMessages.isEmpty) {
    await _error(request.response, HttpStatus.badRequest, 'messages must be a non-empty array.');
    return;
  }
  final messages = <LlamaChatMessage>[];
  try {
    for (final raw in rawMessages) {
      final message = raw as Map<String, dynamic>;
      final role = LlamaChatRole.values.byName(message['role'] as String);
      final content = message['content'];
      if (content is! String) throw const FormatException('Only text message content is supported currently.');
      messages.add(LlamaChatMessage.fromText(role: role, text: content));
    }
  } catch (error) {
    // Log the detail server-side; do not return parser internals to clients.
    stderr.writeln('Invalid messages payload: $error');
    await _error(request.response, HttpStatus.badRequest, 'Invalid messages array.');
    return;
  }

  final temperature = json['temperature'] ?? 0.7;
  if (temperature is! num || !temperature.isFinite) {
    await _error(request.response, HttpStatus.badRequest, 'temperature must be a finite number.');
    return;
  }
  final maxTokens = json['max_tokens'] ?? 2048;
  if (maxTokens is! num || !maxTokens.isFinite ||
      maxTokens <= 0 || maxTokens.toInt() != maxTokens) {
    await _error(request.response, HttpStatus.badRequest, 'max_tokens must be a positive integer.');
    return;
  }
  final stop = json['stop'] ?? const <String>[];
  if (stop is! String &&
      (stop is! List || stop.any((value) => value is! String))) {
    await _error(request.response, HttpStatus.badRequest, 'stop must be a string or an array of strings.');
    return;
  }
  final stream = json['stream'] ?? false;
  if (stream is! bool) {
    await _error(request.response, HttpStatus.badRequest, 'stream must be a boolean.');
    return;
  }
  final params = GenerationParams(
    temp: temperature.toDouble(),
    maxTokens: maxTokens.toInt(),
    stopSequences: stop is String ? [stop] : List<String>.from(stop as List),
  );

  final available = await _availableModels(modelDir);
  _AvailableModel? model;
  for (final candidate in available) {
    if (candidate.id == modelId) {
      model = candidate;
      break;
    }
  }
  if (model == null) {
    await _error(request.response, HttpStatus.notFound, 'Model is not available. Check GET /v1/models.');
    return;
  }

  final engine = LlamaEngine(LlamaBackend());
  var responseStarted = false;
  try {
    await engine.setModel(
      LlamaModel(ModelSource.path(model.path)),
      params: const ModelParams(contextSize: 4096),
    );
    final id = 'chatcmpl-${DateTime.now().millisecondsSinceEpoch}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (stream) {
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8');
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      responseStarted = true;
      await for (final chunk in engine.create(messages, params: params)) {
        final text = chunk.choices.isEmpty ? null : chunk.choices.first.delta.content;
        if (text == null || text.isEmpty) continue;
        request.response.write('data: ${jsonEncode({'id': id, 'object': 'chat.completion.chunk', 'created': created, 'model': model.id, 'choices': [{'index': 0, 'delta': {'content': text}, 'finish_reason': null}]})}\n\n');
        await request.response.flush();
      }
      request.response.write('data: ${jsonEncode({'id': id, 'object': 'chat.completion.chunk', 'created': created, 'model': model.id, 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]})}\n\ndata: [DONE]\n\n');
    } else {
      final output = StringBuffer();
      await for (final chunk in engine.create(messages, params: params)) {
        if (chunk.choices.isNotEmpty) output.write(chunk.choices.first.delta.content ?? '');
      }
      request.response.write(jsonEncode({'id': id, 'object': 'chat.completion', 'created': created, 'model': model.id, 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': output.toString()}, 'finish_reason': 'stop'}]}));
    }
  } catch (error) {
    // Keep internal paths / native error text out of client responses.
    stderr.writeln('Inference failed: $error');
    if (!responseStarted) {
      await _error(request.response, HttpStatus.internalServerError, 'Inference failed.');
    }
  } finally {
    await engine.dispose();
  }
}

Future<void> _error(HttpResponse response, int status, String message) async {
  response.statusCode = status;
  response.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
  response.write(jsonEncode({'error': {'message': message, 'type': 'nomad_error'}}));
  await response.close();
}

class _AvailableModel {
  const _AvailableModel(this.id, this.name, this.path);
  final String id;
  final String name;
  final String path;
}
