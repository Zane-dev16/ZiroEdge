# ZiroEdge

**Privacy-first local AI assistant for iOS.**

Everything runs on your device. No data ever leaves your phone.

## Features

- **On-device AI** — runs multimodal models via llama.cpp, fully offline
- **Conversational AI UI** — message bubbles, streaming responses, markdown rendering
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

Catalog artifacts remain available for storage and verification work, but runtime profiles are hidden from normal chat until their exact configurations pass physical-device acceptance. Download size is never used as a RAM estimate.

See [Runtime memory profiles and calibration](docs/memory-profiles.md) for current evidence, disabled profiles, the production formula, and physical calibration commands.

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
