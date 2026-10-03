# Nomad

> **Derived from [Finn Technologies Flux](https://github.com/Finn-Technologies/flux)** — Nomad builds on Flux's offline-first architecture, retaining its llamadart engine, vision pipeline, and agentic search while adding P-core-aware threading, lazy vision loading, and low-RAM hardening for 4–6 GB devices.

## Overview

Nomad is a fully offline AI assistant for Android. It runs quantized LLMs directly on your device using llamadart (llama.cpp bindings). No accounts, no cloud, no data leaving your phone — ever.

But it can also search the web when you want it to, combining the privacy of local inference with the freshness of live search results.

## Features

### Offline AI Chat

| Model | Size | RAM | What it's good at |
|-------|------|-----|-------------------|
| Nomad Nano | 229 MB | 2 GB+ | Ultra-compact VLM: sub-250ms vision, runs on 2GB RAM |
| Nomad Lite | 533 MB | 3 GB+ | Vision-capable, ultra-fast, sub-1B |
| Nomad Steady | 2.5 GB | 5 GB+ | Multimodal reasoning, vision, balanced speed |
| Nomad Smart | 5.3 GB | 7 GB+ | Flagship: vision, complex analysis, deep reasoning |
| Nomad Pro | 6.0 GB | 16 GB | Powerhouse: coding, agentic tool use, multi-step reasoning |

All models are GGUF quantizations of LFM 2.5 VL 450M (Nano), Qwen 3.5 0.8B (Lite), Gemma 4 E2B/E4B (Steady/Smart), and MiMo V2.6 Distill 9B (Pro), downloaded directly from Hugging Face inside the app via the public CDN (no token needed).

### Vision

Attach an image with the paperclip button and Nomad describes, reads, and reasons about it. All model tiers are vision-capable via native multimodality.

### Web Search (Agentic)

Toggle the globe icon and Nomad becomes an agent — it decides when to search, calls a `web_search` tool, reads the results, and answers based on what it found:

- **TinyFish** — live, uncached browser-rendered search, 100% free via Monid, no anti-bot blocks (default)
- **DuckDuckGo** — zero-config HTML scraper fallback
- **SearXNG** — self-host an instance, point Nomad at your URL

When search is off, everything runs 100% offline.

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

### Voice Live Mode

On-device speech-to-text and text-to-speech with a live waveform composer. Say what's on your mind; Nomad listens, thinks, and talks back.

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

## Getting Started

### Prerequisites

- Android device with 2 GB+ RAM (4 GB+ recommended for Lite, 8 GB for Smart, 16 GB for Pro)
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

# Build a release APK
flutter build apk --release --split-per-abi
```

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
│   │   └── tts_service.dart         # On-device speech
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
| Search      | DuckDuckGo / SearXNG (free)       |
| WebView     | webview_flutter (creation preview) |
| Fonts       | Instrument Sans (Google Fonts)  |
| Icons       | Custom SVGs + Material Symbols  |

## Privacy

Nomad is built with privacy as a hard requirement:

- **No account** — download and start using immediately
- **No cloud** — inference runs locally via llama.cpp
- **No telemetry** — zero analytics, zero tracking
- **No internet needed** — fully offline when search is toggled off

## What's New in v0.2.0

- **Nomad Nano tier** — Liquid AI LFM 2.5 VL 450M (`Q4_K_M`, 229 MB) bringing vision & chat to ultra-low-memory 2 GB RAM devices
- **Nomad Pro tier** — Xiaomi MiMo V2.6 Distill 9B (`Q4_K_M`) powerhouse for coding, tool use, and multi-step reasoning on 16GB devices
- **TinyFish Web Search** — live, uncached browser-rendered search via Monid as default web search (100% free, fast, bypasses anti-bot blocks)
