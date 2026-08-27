# Contributing to ZiroEdge

Thank you for considering a contribution. ZiroEdge is an iOS app built with Swift and SwiftUI that runs language models entirely on device. This guide covers getting the app running locally, how we build and test, and what we expect in commits and pull requests.

## What you need

- A Mac with Xcode 15 or newer installed.
- Swift 5.9 or newer, which ships with Xcode.
- iOS 18 is the deployment target, so use a recent simulator runtime or device.
- XcodeGen, which generates the Xcode project from `app/project.yml`. Install it with `brew install xcodegen` if you do not already have it.
- An Apple Developer account if you want to run on physical hardware. Signing is automatic, but you may need to select your own team in the signing settings before deploying to a device.

## Quick start

All iOS work happens under `app/`. From a fresh clone:

```bash
cd app
chmod +x setup.sh && ./setup.sh
xcodegen generate
open ZiroEdge.xcodeproj
```

What each step does:

1. `./setup.sh` downloads a prebuilt inference engine binary into the local Swift package that wraps it. Rerun it if builds fail because local binaries are missing.
2. `xcodegen generate` produces the Xcode project from `project.yml`. The project file is generated, not hand maintained, so rerun this command any time `project.yml` changes.
3. Open the generated project in Xcode, pick a simulator, and run.

If you just cloned the repository without running setup, expect missing-binary errors on the first build. Running setup again fixes it.

## Building

From Xcode, choose the app scheme and build or run as usual. To verify from the command line:

```bash
xcodebuild -scheme ZiroEdge -destination 'generic/platform=iOS' build
```

Always regenerate the project with `xcodegen generate` first if you have touched `project.yml`, target settings, or entitlements configuration.

## Testing

There are three layers of tests:

- Unit tests live in the app's unit test target and run against the main scheme. Run them from Xcode with Cmd+U, or with `xcodebuild test -scheme ZiroEdge` using an iOS simulator destination of your choice.
- UI tests live in a separate UI test scheme and exercise full flows through the interface. They are slower, so run them when your change touches user-facing behavior.
- Python release-gate tests validate the scripts that ship with the app. Run them from the directory containing the `Scripts` folder:

  ```bash
  python3 -m unittest discover -s Scripts/Tests
  ```

Before opening a pull request, run the unit suite at minimum, plus whichever other suites cover your change.

## Release gates

Shell and Python tooling under `app/Scripts/` collects diagnostics and evidence, then produces verdicts used to decide whether a build may ship. Treat these gates as blocking pre-release checks, not suggestions. If your change affects shipping behavior, expect reviewers to ask for fresh gate evidence. Never edit gate logic or hand-edit evidence files just to flip a red verdict to green; fix the underlying issue instead.

## Where things live

A rough map so you can orient yourself. Details shift as the code evolves, so treat folder names as the contract:

- `app/`: the XcodeGen project and the application itself.
- `app/ZiroEdge/`: SwiftUI sources layered with interface code at the top, then state handling, then services, then persistence.
- `app/Packages/`: local Swift packages, including the wrapper around the on-device inference engine.
- `app/Scripts/`: developer tooling for diagnostics, screenshots, and release evidence.
- `app/AppStore/`: release and store submission materials.
- `docs/` and `test-output/`: documentation and working output directories at the repository root.

When adding features, keep view code small and push decisions down: views declare what users see, coordination logic lives below the interface layer, persistence stays behind its storage types, and all model loading and generation calls go through the local inference package rather than reaching the engine directly elsewhere.

## Code style

- Write idiomatic modern Swift and SwiftUI. Follow the formatting and patterns already present in nearby code rather than introducing a second style.
- Prefer small, single-purpose views and types with clear responsibilities over long files doing many jobs.
- Keep business logic testable without launching the simulator, which means separating decisions from rendering.
- Use explicit access control, early returns, and names drawn from the product domain instead of abbreviations.
- Add or update tests alongside behavior changes. A feature without coverage is a future bug with no alarm bell.
- Keep custom controls labeled and screens navigable with VoiceOver. On-device-first software should be usable by everyone.

Comment sparingly and explain why, not what. If something looks surprising enough to need a comment, consider whether renaming or restructuring removes the surprise first.

## Commit messages

We follow Conventional Commits:

```
type(scope): short imperative summary
```

Common types:

- `feat`: new capability or behavior
- `fix`: bug fix
- `refactor`: restructuring with no intended behavior change
- `test`: adding or adjusting tests
- `docs`: documentation only
- `chore`: maintenance work that fits no other type
- `build`: project generation, dependencies, or packaging
- `perf`: performance improvements

The scope is optional but encouraged. Name the area the change touches, such as `download`, `chat`, `persistence`, `release`, or `scripts`.

Examples:

```
feat(download): resume partially fetched models
fix(persistence): keep drafts across relaunches
refactor(scripts): share logging helpers
docs: update setup instructions
```

Keep summaries short, present tense, and imperative. Use the commit body for context when the reason behind a change is not obvious from the diff.

## Pull requests

- Branch from the latest default branch and keep each pull request focused on one coherent change. Small reviews get faster feedback.
- Rerun `xcodegen generate` if `project.yml` changed, then build once before pushing.
- Run relevant test suites locally and note which ones you ran in the description.
- Describe the motivation and user-visible impact. For interface changes, attach screenshots or a short clip.
- When sharing verification output, paste the short verdict lines rather than whole logs, since evidence directories are not tracked.
- If your change adds a dependency, check that its license is compatible with ours and add an entry to `THIRD_PARTY_NOTICES.md`.
- Link related issues where they exist, and expect questions during review. Answering them well moves things faster than expanding the diff.

Reviews aim to be kind and specific. Suggestions are about the code, never the person.

## Generated files and evidence directories

Machine-produced output stays out of version control. This includes binaries fetched by setup, derived caches and build products, screenshots and diagnostic dumps produced by tooling, and evidence written to output directories such as `test-output/`. As a rule of thumb: if a command created the file, assume it should remain untracked unless a maintainer says otherwise. Anything you need can be regenerated by rerunning the tool that made it.

Do not commit local secrets, signing artifacts, or personal team identifiers either.

## License

ZiroEdge is MIT licensed. By contributing, you agree that your changes carry the same license. If you introduce third-party code or libraries, make sure their licenses are compatible and record them in `THIRD_PARTY_NOTICES.md`.

## Questions

If something in this document does not match what you see in the repository, open an issue or send a pull request fixing this file. Documentation rots fastest when nobody touches it, and the person who hit the mismatch yesterday is exactly who fixes it today.
