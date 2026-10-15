# ZiroEdge

ZiroEdge runs AI right on your iPhone. You pick any model you like from Hugging Face, download it, then you can turn on airplane mode and keep chatting, even about photos.

## Setup

```bash
git clone https://github.com/Zane-dev16/ZiroEdge.git
cd ZiroEdge
chmod +x setup.sh
./setup.sh
open ZiroEdge.xcodeproj
```

`./setup.sh` downloads the llama.cpp xcframework binary (b9821) into `Packages/swift-llama-cpp`. Build from Xcode or from the command line:

```bash
xcodebuild -scheme ZiroEdge -destination 'generic/platform=iOS' build
```

Requires Xcode 15.0+, iOS 18.0+, Swift 5.9+.

Docs: [download spec](docs/download-spec.md), [download architecture](docs/download-architecture.md), [download testing](docs/download-testing.md), [memory profiles](docs/memory-profiles.md), [release gates](docs/release-gates.md).

## License

MIT, Copyright 2026 Irell Zane. See LICENSE.

Third-party: llama.cpp (MIT). Model licenses vary by model.
