# ZiroEdge

ZiroEdge runs AI right on your iPhone. You pick any model you like from Hugging Face and download it. Even on airplane mode, it keeps chatting, even about photos.

## Setup

```bash
git clone https://github.com/Zane-dev16/ZiroEdge.git
cd ZiroEdge
chmod +x setup.sh
./setup.sh
open ZiroEdge.xcodeproj
```

`./setup.sh` builds the pinned llama.cpp XCFramework (b12000) with
`Scripts/build-llama-xcframework.sh` and installs it into
`Packages/swift-llama-cpp`. Build from Xcode or from the command line:

```bash
xcodebuild -scheme ZiroEdge -destination 'generic/platform=iOS' build
```

Requires Xcode 15.0+, iOS 18.0+, Swift 5.9+, cmake 3.28+.

Docs: [download spec](docs/download-spec.md), [download architecture](docs/download-architecture.md), [download testing](docs/download-testing.md), [memory profiles](docs/memory-profiles.md), [llama.cpp runtime](docs/llama-runtime.md), [release gates](docs/release-gates.md).

## License

MIT, Copyright 2026 Irell Zane. See LICENSE.

Third-party: llama.cpp (MIT). Model licenses vary by model.
