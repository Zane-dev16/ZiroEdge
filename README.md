# ZiroEdge

**Privacy-first local AI assistant for iOS.**

Everything runs on your device. No data ever leaves your phone.

## Features

- **On-device AI** — runs multimodal models via llama.cpp, fully offline
- **ChatGPT-style UI** — conversation sidebar, message bubbles, streaming
- **Vision support** (Phase 2) — camera + photo library input
- **Core Data persistence** — conversations survive cold restarts
- **Conversation branching** — fork from any message
- **Markdown rendering** — bold, italic, code blocks, lists

## Architecture

```
┌─────────────────────────────────────────┐
│  Views (SwiftUI)                        │
│  ChatView · SidebarView · SettingsView  │
├─────────────────────────────────────────┤
│  ViewModels                             │
│  ChatViewModel · ConversationListVM     │
├─────────────────────────────────────────┤
│  Services (no llama types leak above)   │
│  InferenceService · ModelLifecycleMgr   │
│  MemoryBudgeter · ChatSessionActor      │
│  MarkdownRenderer · ModelManagerService │
├─────────────────────────────────────────┤
│  Persistence (Core Data)                │
│  Conversation · ChatMessage             │
├─────────────────────────────────────────┤
│  Packages                               │
│  swift-llama-cpp (upstream b9821)       │
└─────────────────────────────────────────┘
```

## Models

| Model | Type | Quant | Size | RAM Floor |
|-------|------|-------|------|-----------|
| Llama 3.2 3B | Text | Q4_K_M | ~2 GB | 3.5 GB |

Vision models (Phase 2): SmolVLM 500M, Qwen 2.5-VL 3B.

## Setup

```bash
git clone https://github.com/Zane-dev16/ZiroEdge.git
cd ZiroEdge
chmod +x setup.sh
./setup.sh
open ZiroEdge.xcodeproj
```

The setup script downloads the llama.cpp xcframework binary (upstream release b9821).

## Build

```bash
xcodebuild -scheme ZiroEdge -destination 'generic/platform=iOS' build
```

## Requirements

- Xcode 15.0+
- iOS 18.0+
- Swift 5.9+

## License

MIT — Copyright 2026 Irell Zane. See [LICENSE](LICENSE).

## Third-Party Notices

- [llama.cpp](https://github.com/ggml-org/llama.cpp) — MIT License
- Model licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
