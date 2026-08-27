# Changelog

All notable changes to ZiroEdge are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Headless import runner that verifies model imports end to end for automated regression testing.
- Vision support in the import runner so multimodal input can be verified alongside text.

### Fixed

- Resumed downloads validate against the complete artifact instead of failing near completion.
- Verified transfers no longer stall out, and staged data survives interrupted install promotions.
- Download statuses refresh correctly after legacy migration relocates stored files.
- Artifacts stranded by interrupted installs are reclaimed instead of leaking storage.
- Unreadable artifacts report as I/O issues rather than hash mismatches, so diagnostics stay accurate.
- Stop honors requests made while start is suspended, and active streams detach when switching conversations.
- Launch scripts for diagnostics pass the flags the app actually consumes.

### Changed

- Cleaned up internal dead code and removed an unused entitlement carried over from earlier development.

## [1.0.0] - 2026-08-25

### Added

- Initial public release.
