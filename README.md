# Nomad

> **Derived from [Finn Technologies Flux](https://github.com/Finn-Technologies/flux)** — Nomad builds on Flux's offline-first architecture, retaining its llamadart engine, vision pipeline, and agentic search while adding P-core-aware threading, lazy vision loading, and low-RAM hardening for 4–6 GB devices.

## Overview

Nomad is an offline-first AI assistant for Android. It runs quantized LLMs directly on your device using llamadart (llama.cpp bindings), without an account or a cloud inference service. Optional web search and the device's speech services can use the network.

But it can also search the web when you want it to, combining the privacy of local inference with the freshness of live search results.

## Features

### Offline AI Chat

| Model | Size | RAM | What it's good at |
|-------|------|-----|-------------------|
| Nomad Lite | 533 MB | 3 GB+ | Vision-capable, ultra-fast, sub-1B |
| Nomad Omni | 1.0 GB | 6 GB+ | LFM3 Omni 2B: text, image and audio input, text or speech output |
| Nomad Steady | 1.0 GB | 4 GB+ | LFM3-VL-2B: multimodal reasoning, vision, video understanding |
| Nomad Smart | 5.3 GB | 7 GB+ | Flagship: vision, complex analysis, deep reasoning |
| Nomad Pro | 6.0 GB | 16 GB | Powerhouse: coding, agentic tool use, multi-step reasoning |

All models are GGUF quantizations of Qwen 3.5 0.8B (Lite), LFM3-VL-2B (Steady), LFM3 Omni 2B (Omni), Gemma 4 E4B (Smart), and MiMo V2.6 Distill 9B (Pro), downloaded directly from Hugging Face inside the app via the public CDN (no token needed).

### Vision

Attach an image with the paperclip button and Nomad describes, reads, and reasons about it. All model tiers are vision-capable via native multimodality.

### Web Search (Agentic)

Toggle the globe icon and Nomad becomes an agent — it decides when to search, calls a `web_search` tool, reads the results, and answers based on what it found:

- **TinyFish** — live, uncached browser-rendered search, 100% free via Monid, no anti-bot blocks (default)
- **DuckDuckGo** — zero-config HTML scraper fallback
- **SearXNG** — self-host an instance, point Nomad at your URL (LAN instances like `http://192.168.1.10:8888` work; Android 17 needs the local-network permission the app declares)
- **Brave Search API** — optional bring-your-own key in Settings; no API key is ever bundled in the APK

When search is off, downloaded-model text inference runs locally. Speech recognition follows the device's speech-provider settings and may still require a connection.

### App Builder ("Creations")

Describe an HTML/CSS/JS mini-app in natural language and Nomad Lite will build it. The app gets a live preview, auto-saves to your collection, and you can run, edit, or delete creations.

### Conversation History

Every chat auto-saves. The history sidebar lets you browse, rename, or delete past conversations. When you tap an old chat, the model used for that conversation is automatically restored.

### Nomad Code Server (Desktop)

Nomad's desktop app stores downloaded models in `Documents/Nomad/models`, which can also be served to coding tools through the standalone OpenAI-compatible API in [`server/`](server/README.md). Start it with Dart and point OpenCode or another harness at `http://127.0.0.1:8787/v1`. The server exposes downloaded models through `/v1/models` and text chat through `/v1/chat/completions`.

### Context Management

Nomad proactively monitors its context window. When it hits 70% capacity, older conversation turns are automatically summarized into a compact history — no context overflows, no lost memory.

### Long Responses Without Crashing

Text streams in live as it's generated. Responses that get cut off automatically continue where they left off so no output is lost.

### Voice Assistant

Tap **Nomad Voice** in the chat composer. Nomad shows its listening, processing, thinking, and speaking state, streams short spoken answers, and listens for a follow-up only after playback finishes. Tap the middle button to interrupt, **Pause voice** to pause, or **End voice** / **Type instead** to return to typing. Leaving the app or the screen closes the microphone; it does not silently restart on resume.

For the Android system shortcut, use **Settings → Digital Assistant** to select Nomad, then invoke your device's assistant gesture/button. Cold starts and repeated invocations use the same voice session. Complete onboarding first and grant microphone access when prompted. This is an explicitly invoked assistant, not an always-on wake-word listener.

- Questions use your selected downloaded model and are saved in conversation history. Enable **Web search** in the voice panel when you want the model to look up current information.
- Common English phone commands work without a model: “open YouTube”, “set a timer for ten minutes”, “set an alarm for 7:30 AM”, “navigate to the nearest pharmacy”, “open Wi-Fi settings”, “call 555 123 4567”, “text 555 123 4567 saying I'm running late”, “play music”, “turn it up”, “mute”, “how much battery do I have?”, “open example.com”, and “what time is it?”. The same commands work when typed, and the model can request any of them through the `phone_action` tool for other phrasings.
- Timers/alarms open the device's Clock app with the requested details; calls open the dialer, texts open Messages with the number and body filled in, and settings commands open the relevant controls rather than claiming to toggle restricted Android settings. Media and volume commands send standard playback keys and change only the media stream, which some players or devices may ignore while Do Not Disturb is active.
- Recognition uses an installed system speech provider (such as Google's or Samsung's). Its language packs, network requirements, and offline support depend on that provider. Playback prefers an installed local TTS voice matching the device language.
- Permission, missing-provider, language, network, model, and playback errors have visible recovery controls. Voice uses temporary audio focus and never changes alarm, ringtone, or notification volume.

Automated tests exercise late recognition results, interruption, playback completion, permission recovery, navigation, and assistant launches. A real Android device is still needed to verify microphone acoustics, OEM assistant gestures, Bluetooth routing, and the device's recognition/Clock apps.

### Localized UI

The entire interface is translated into 6 languages:

| Language | Locale |
|----------|--------|
| English  | en     |
| Spanish  | es     |
| French   | fr     |
| German   | de     |
| Italian  | it     |
| Chinese  | zh     |

### Engineered for 2–6 GB Phones

Smooth at the low end, not just on flagships: big-core-aware thread detection (avoids the MediaTek efficiency-core scheduling collapse), flash attention + quantized KV cache (≈50% less RAM), lazy vision-encoder loading on constrained devices, adaptive streaming throttle, and serialized model loads to prevent native OOM spikes.

### 4 GB Memory Profile

Phones with 4 GB RAM or less load models on demand rather than preloading them at startup. Onboarding recommends Lite; the full Models catalog remains visible, but the low-memory runtime rejects incompatible or oversized models without deleting their downloads.

- Android free-memory checks reserve 512 MiB beyond the model file size and 256 MiB beyond an additional vision projector. These are conservative estimates, not measured peak-memory guarantees.
- Vision processes one image at a time, with gallery inputs resized to at most 512 x 512. The projector is released after a response, cancellation, or generation error, while the text model stays available.
- Model loads and disposal are serialized. A second response cannot race the current native decode. Backgrounding a low-memory phone or receiving a memory-pressure signal requests release once inference is idle.
- The image cache is capped at 24 MiB / 50 entries on low-memory phones, parsed-reply caches have a source-text budget, and streaming UI updates are coalesced to at most 10 per second during generation.

Real-device validation is still required: profile sustained chat, image requests, model switches, and background/resume on a 4 GB Android device. Use `adb shell dumpsys meminfo com.varun.nomad` alongside Flutter profile-mode frame timings; do not infer crash-free operation or tokens/second from desktop unit tests. Higher-memory model/context defaults are unchanged.

## Getting Started

### Prerequisites

- Android device with 2 GB+ RAM (4 GB+ recommended for Lite and Steady, 8 GB for Smart, 16 GB for Pro)
- Flutter SDK (stable) for development
- Android Studio, VS Code, or IntelliJ

### Installation

```sh
# Clone
git clone https://github.com/varun875/nomad.git
cd nomad

# Dependencies
flutter pub get

# Run on a connected device
flutter run

# Build a release APK (signed via android/key.properties + a personal
# keystore; falls back to debug signing when absent)
flutter build apk --release --split-per-abi
```

### Release signing

Release builds are signed with a personal keystore kept out of git:

```sh
keytool -genkey -v -keystore android/app/nomad-release.jks -keyalg RSA \
  -keysize 2048 -validity 10000 -alias nomad
```

Then create `android/key.properties` with `storePassword`, `keyPassword`,
`keyAlias=nomad`, and `storeFile=nomad-release.jks`. Both files are gitignored;
keep a backup of the keystore and passwords — losing them means existing
installs cannot be updated.

## Architecture

```
lib/
├── main.dart                    # Entry point, GoRouter, service bootstrap
├── core/
│   ├── constants/               # AppVersion, etc.
│   ├── models/                  # Model & conversation data structures
│   ├── services/
│   │   ├── inference_service.dart   # llama.cpp streaming inference, threading
│   │   ├── model_service.dart       # RAM-filtered model catalog
│   │   ├── search_service.dart      # DuckDuckGo / SearXNG (free)
│   │   ├── performance_service.dart # Device-tier detection for effects/perf
│   │   ├── memory_service.dart      # Local recall store
│   │   ├── voice_session_controller.dart # Voice turn-taking, cancellation, recovery
│   │   ├── assistant_platform_service.dart # Android launches and phone actions
│   │   ├── speech_input_service.dart # System speech-recognition adapter
│   │   └── tts_service.dart         # Locale-aware, cancellable spoken replies
│   ├── providers/               # Riverpod state (downloads, models, chats)
│   ├── theme/                   # NomadColors, light/dark themes (Instrument Sans)
│   └── widgets/                 # Shared UI, tier-aware animations
├── features/
│   ├── onboarding/              # Welcome flow + model selection
│   ├── chat/                    # Main chat, streaming, voice live mode
│   ├── models/                  # Download library + storage info
│   ├── creations/               # App builder gallery, editor, preview
│   ├── skills/                  # Tools & agent registry
│   ├── you/                     # Personalization
│   └── settings/                # Cache, search keys, about, version
├── l10n/                        # ARB + generated Dart (6 languages)
└── assets/
    ├── images/                  # SVG icons
    └── icon/                    # App icon (PNG)
```

## Tech Stack

| Layer       | Choice                          |
|-------------|---------------------------------|
| Framework   | Flutter 3.x                     |
| State       | Riverpod 2.x                    |
| Routing     | go_router                       |
| Local DB    | Hive + SharedPreferences        |
| AI Engine   | llama.cpp via llamadart         |
| Downloads   | background_downloader           |
| Search      | TinyFish / DuckDuckGo / SearXNG / Brave (BYOK) |
| WebView     | webview_flutter (creation preview) |
| Fonts       | Instrument Sans (Google Fonts)  |
| Icons       | Custom SVGs + Material Symbols  |

## Privacy

Nomad is built with privacy as a hard requirement:

- **No account** — download and start using immediately
- **Local inference** — model inference runs locally via llama.cpp
- **No telemetry** — zero analytics, zero tracking
- **Offline text chat** — downloaded-model text chat works without internet. Web search and the selected system speech provider may send requests over the network.

## What's New in v0.2.0

- **Nomad Steady on 4 GB phones** — Liquid AI LFM3-VL-2B (`QAD Q4_0`, 1.0 GB + 203 MB projector) replaces LFM 2.5 VL 3B: ~540 MB smaller, adds video understanding and thinking, and drops the RAM recommendation from 5 GB+ to 4 GB+
- **Search your way** — optional SearXNG (self-hosted, LAN supported) and Brave Search API (bring-your-own key) backends, plus a Wi-Fi-only downloads toggle and free-storage checks before model downloads
- **Nomad Pro tier** — Xiaomi MiMo V2.6 Distill 9B (`Q4_K_M`) powerhouse for coding, tool use, and multi-step reasoning on 16GB devices
- **TinyFish Web Search** — live, uncached browser-rendered search via Monid as default web search (100% free, fast, bypasses anti-bot blocks)
