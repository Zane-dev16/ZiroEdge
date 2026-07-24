# Release validation — blockers 2–5

Date: 2026-07-24

## Environment

- Xcode 26.6 (17F113)
- iOS Simulator 26.5, iPhone 17 Pro
  (`C0E3F869-1E02-47D7-8E9B-71CEB7AB55E0`)
- Tests ran nonparallel with signing disabled.
- No signing or account settings were changed.

## Evidence

### Persistence and startup recovery

The focused persistence, store-recovery, and runtime suites passed: 15 tests,
0 failures. Coverage includes a real corrupt-SQLite load callback failure,
injected out-of-space and generic save failures, rollback, failed periodic flush,
canonical retry content, global recovery ownership, process-style journal replay,
partial quarantine cleanup, verified destruction, reopen, sanitized diagnostics,
and user retry.

The store-load path returns a typed result and does not call `fatalError`.
Startup recovery is nondestructive. Reset is available only for a disk store after
a verified quarantine artifact is created and the user confirms that exact
artifact.

### Complete simulator suite

A clean nonparallel run passed:

- 239 tests executed
- 3 tests skipped
- 0 failures
- Result bundle:
  `/tmp/ZiroEdge-FullTests4/Logs/Test/`
  `Test-ZiroEdge-2026.07.24_08-40-26-+0800.xcresult`

### Release build and archive

A clean unsigned generic-iOS Release build passed with DerivedData at
`/tmp/ZiroEdge-ReleaseFinal`.

A clean unsigned generic-iOS archive passed at
`/tmp/ZiroEdge-release-final.xcarchive`. The archive contains the app,
`PrivacyInfo.xcprivacy`, and `ZiroEdge.app.dSYM`. This proves local archive
feasibility only; it does not claim signing or distribution readiness.

### Thread Sanitizer

The simulator `build-for-testing` command with
`-enableThreadSanitizer YES` failed before compilation for the app and tests:

```text
error: Could not get lib darwin path
```

This is an Xcode 26.6/iOS 26.5 toolchain limitation. No TSan-clean runtime claim
is made. Normal builds succeed without warnings from project-owned source. The
vendored `swift-llama-cpp` wrapper still emits Swift 6 isolation and pointer-
lifetime warnings that must be resolved before adopting Swift 6 language mode.

### Static and metadata validation

- Primary LSP diagnostics: 0 diagnostics in 8 changed release-critical files.
- `git diff --check`: passed.
- Privacy manifest and entitlement plist syntax: passed.
- Catalog validator unit tests: 3 passed.
- Production catalog validation: expected exit 1 because
  `llama3.2-3b-q4` has no authoritative base SHA-256.

Blocker 1 remains intentionally fail-closed. No digest was invented and
production integrity validation was not weakened.

## Commands

```sh
xcodebuild test -project ZiroEdge.xcodeproj -scheme ZiroEdge \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath /tmp/ZiroEdge-FullTests4 \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

xcodebuild -project ZiroEdge.xcodeproj -scheme ZiroEdge \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/ZiroEdge-ReleaseFinal \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -project ZiroEdge.xcodeproj -scheme ZiroEdge \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/ZiroEdge-ArchiveFinal archive \
  -archivePath /tmp/ZiroEdge-release-final.xcarchive \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

xcodebuild build-for-testing -project ZiroEdge.xcodeproj \
  -scheme ZiroEdge -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath /tmp/ZiroEdge-TSan -enableThreadSanitizer YES \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

python3 -m unittest discover -s Scripts/Tests -p 'test_*.py'
python3 Scripts/verify-model-catalog.py
plutil -lint ZiroEdge/Resources/PrivacyInfo.xcprivacy \
  ZiroEdge/ZiroEdge.entitlements
```

## Not verified locally

- Physical-device disk pressure and process-kill durability
- Background expiration and share-sheet UX on hardware
- Real GGUF inference
- Signed installation or distribution
- TSan execution on a supported toolchain
- Swift 6 warning-free compilation

Simulator evidence does not replace physical-device durability evidence.
