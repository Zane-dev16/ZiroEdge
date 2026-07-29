# Runtime memory profiles and calibration

Runtime memory admission is independent of GGUF and projector download sizes. Artifact sizes are used only for download, integrity, and storage UI.

## Production policy

A profile is production-eligible only after its exact text or vision runtime shape completes physical acceptance. Unknown, partial, and unvalidated profiles fail closed.

For a validated profile:

1. Take the maximum measured full-workload physical-footprint delta across every accepted run and device.
2. Multiply by `1.25`.
3. Round up to the next `100,000,000` bytes.
4. Add a fixed `750,000,000` byte reserve.
5. Require the profile's minimum physical RAM and the resulting process headroom before native construction.
6. After load, require at least the fixed reserve from one new process-headroom sample.

When replacing an already loaded model, native unload must finish and a five-second recovery window must complete before the single admission sample. There is no arbitrary fallback headroom.

## Current evidence

| Profile | Runtime shape | Evidence | Production |
| --- | --- | --- | --- |
| Gemma 4 E2B vision | projector required, context 4096, batch 512, microbatch 128 | Accepted on target `00008140-000178A1362B001C`: five measured cycles, 20 text prompts, five image turns, background/foreground, peak delta 798,559,232 bytes, required headroom 1,750,000,000 bytes | Validated |
| Gemma 4 E4B text calibration | no projector, context 512, batch 256, microbatch 64, mmap enabled, CPU settings unchanged | Unvalidated | Disabled |
| Gemma 4 E4B vision | projector required, context 4096, batch 512, microbatch 128 | Unvalidated | Disabled |
| Llama 3.2 3B text | context 4096, batch 512, microbatch 128 | Unvalidated | Disabled |

The retained E2B load-only delta remains 790,334,488 bytes for diagnostic history; production admission uses the larger accepted full-workload peak of 798,559,232 bytes. Configured context, batch, and microbatch values are specified runtime controls, not measurements. Evidence is retained under `test-output/memory-diagnostic-e2b-round1-warm-20260726T165800Z/`.

## Physical calibration

Calibration is DEBUG-only and never appears in Release. The E4B text identity reuses ZiroEdge's registered and SHA-256-verified base artifact in its own managed container. It does not copy data from another app and does not request a projector.

```bash
bash Scripts/ram-diagnose.sh \
  --expect load \
  --calibration-load \
  --controlled-workload \
  --model e4b \
  --profile text \
  --device <UDID>
```

Use `--profile vision` for the separate E4B vision run. Acceptance requires:

- five cold load/unload cycles;
- 20 text prompts, including long-context pressure;
- an image turn in each cycle only for a vision profile;
- a background/foreground transition;
- 100 ms physical-footprint and process-headroom samples;
- JSONL synchronization after every record;
- five-second post-unload recovery within 100 MB of each cycle baseline;
- no upward recovery trend;
- no warning, reserve breach, jetsam, crash, hang, or corrupt output;
- retained JSONL, raw logs, and both xcresult bundles.

The workload stops at the first warning or fixed-reserve breach. Missing
artifacts fail the script. The JSONL can also be exported in DEBUG Settings.

## Crash resistance

Memory pressure and background transitions cancel generation and unload; they
never auto-reload. A pending-load marker is atomically persisted immediately
before native construction and cleared as soon as construction returns. This
prevents ordinary termination after a successful load from being classified as
a crash. Two unclean attempts among the retained last five disable that exact
profile until explicit reset.

Native model/context/projector construction is synchronous and cannot be
interrupted once entered. Pressure handling is therefore registered before
construction. Failures are classified as model mapping, context creation,
projector initialization, inference, memory pressure, or suspected interrupted
load. User-facing errors omit local paths while bounded sanitized diagnostics
retain the underlying category.
