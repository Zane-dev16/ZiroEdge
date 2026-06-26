# ZiroEdge

Privacy-first local AI assistant for iOS.

Runs multimodal models entirely on-device. No data ever leaves your phone.

## Features

- **Chat + Vision** — send images for analysis via camera or photo library
- **Conversation History** — all conversations persisted locally via Core Data
- **Multiple Models** — curated catalog of small, fast models (500M–3B params)
- **Conversation Branching** — fork conversations from any point
- **System Prompts** — customize the AI's behavior per conversation
- **Sampling Controls** — temperature, top-p, top-k for power users
- **Streaming** — real-time token-by-token output with haptic feedback
- **Offline** — works without network after initial model download

## Architecture

- **Engine**: Upstream `ggml-org/llama.cpp` via SPM (pinned, no fork)
- **Persistence**: Core Data with background writer context
- **UI**: SwiftUI, ChatGPT-style conversation interface
- **Memory**: mmap loading, f16_kv, MemoryBudgeter pre-load checks
- **Platform**: iOS 18.0+

## Models

| Model | Type | Size | Notes |
|-------|------|------|-------|
| SmolVLM 500M | Vision | ~550 MB | Starter. Runs on all iOS 18 devices. |
| Qwen 2.5-VL 3B | Vision | ~2.2 GB | Device-gated. Requires 6 GB+ RAM. |
| Llama 3.2 3B | Text | ~2 GB | Fast text-only chat. |

## Building

```bash
xcodebuild -scheme ZiroEdge -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## License

MIT. See [LICENSE](LICENSE).

Model weights are subject to their own licenses. See Settings → Licenses in-app.
