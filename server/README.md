# Nomad Code Server

Standalone desktop API server for GGUF models downloaded by Nomad. It serves the OpenAI-compatible `GET /v1/models` and `POST /v1/chat/completions` endpoints, including server-sent event streaming.

## Requirements

- Dart SDK 3.10.7 or newer
- A downloaded Nomad model

Nomad desktop stores new model downloads in `Documents/Nomad/models`. Existing downloads in `Documents/models` are also discovered. You can pass another directory with `--models-dir`.

## Run

```powershell
cd server
dart pub get
dart run bin/nomad_code_server.dart
```

The server listens on `127.0.0.1:8787` by default, but `NOMAD_API_KEY` is **required** (`/health` is the only unauthenticated endpoint). Without it any local process, or any website open in your browser, could call the model. Set it before starting the server:

```powershell
$env:NOMAD_API_KEY = "choose-a-local-secret"
dart run bin/nomad_code_server.dart
```

To allow another machine on your LAN to connect, also bind explicitly:

```powershell
$env:NOMAD_API_KEY = "choose-a-local-secret"
dart run bin/nomad_code_server.dart --host 0.0.0.0 --port 8787 --models-dir "$HOME\Documents\Nomad\models"
```

Browser clients are blocked by default because no CORS headers are sent. To allow one web origin, set `NOMAD_ALLOWED_ORIGIN` to that exact origin (e.g. `http://localhost:3000`).

## OpenCode

Configure OpenCode with the server URL `http://127.0.0.1:8787/v1` and one of the model IDs returned by `GET /v1/models`. Use `NOMAD_API_KEY` as the provider API key.

The first implementation supports text messages, temperature, max tokens, stop strings, and streaming. It loads a model for each completion and disposes it afterward. Requests are serialized to keep memory use predictable.
