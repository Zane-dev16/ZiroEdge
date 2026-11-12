# Runtime memory profiles and calibration

Runtime memory admission is independent of GGUF and projector download sizes. Artifact sizes are used only for download, integrity, and storage UI.

## GPU tiering

Runtime is auto-tiered: full Metal GPU offload on 8GB+ devices, CPU-only below (`ModelConfiguration.autoGpuLayers()`). Each tier is a separate runtime shape with independent evidence — an uncalibrated Metal shape fails closed to CPU instead of refusing a load CPU could serve.

One family is exempt from the tier: **Gemma 4 E4B** (vision and text) is pinned to `gpuLayers: 0` on every device, and registers no Metal shape at all. Its base artifact is 4.97 GB, and full offload of that is admitted by the RAM tier and then dies at the first decode:

```
error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)
ggml_metal_graph_compute: backend is in error state from a previous command buffer failure
llama_decode: failed to decode, ret = -3
```

Measured twice on iPhone 16 (2026-11-10, 2026-11-11). The process footprint after load was 74 MB, so the weights live in GPU memory that process-headroom admission cannot see: the tier has no way to notice. E2B's 3.19 GB base offloads on the same device, and llama 3.2's 2.02 GB base answers on the Metal shape. The safe shape is therefore no offload, not a size heuristic — a size-aware tier would need a measured GPU budget to anchor it, and inventing one is what put a shipped row in a decode-failing state.

Consequence: the E4B Metal profile ids (`gemma4-e4b-text-metal-p1`, `gemma4-e4b-vision-metal-p1`) no longer exist. Restore one only alongside a measured size-aware tier. Load-safety history keyed to those ids is inert, not migrated — those shapes cannot be selected again.

## Production policy

A load is admitted when the runtime has a number to compare against the device's free memory. Where that number comes from decides the tier:

| Tier | Number comes from | Consent | Result |
| --- | --- | --- | --- |
| `validated` | Measured full workload on a retained device | No | Strict policy (below) |
| `experimental` | Measured load delta only | Yes, per shape | Conservative floor |
| `estimated` | Conservative static estimate from the catalog row | No | Conservative floor |
| `unavailable` | Nothing | — | Refused |

`unavailable` is not a state a shipped model may reach. `ModelCatalogValidator.catalogFailureReason` refuses a catalog containing such a row, and `ModelAvailabilityTaxonomyTests` proves it, because a row the runtime will not load is a product defect that reads to the user as a broken app.

### The estimate tier

A curated shape with no device measurement is sized by `ImportRAMAssessment.residentBytes` — the same arithmetic the import wizard shows a user before a download. One estimator, three consumers (wizard, imported admission, curated estimate), so a model cannot be advertised as "likely fits" and then refused at load time.

The estimate deliberately over-states, and the direction is the point:

- Weights ride llama.cpp's mmap path on CPU and Metal alike, so a third of the file is charged. The retained E2B full-workload peak (798,559,232 bytes for a 3,985MB pair) sits below even `base/3` alone.
- Context charges 256KB per token, roughly twice the f16 KV a 3B-class shape allocates.

An estimate that is too high refuses a load that would have fit — annoying and recoverable. An estimate that is too low admits one that does not — jetsam. Only one of those directions is acceptable, so the arithmetic errs high and the post-load reserve check still runs.

Calibration identities never carry an estimate: they exist to gather the first measurement, and sizing them from artifact bytes would make the measurement run unnecessary.

### Validated profiles

For a validated profile:

1. Take the maximum measured full-workload physical-footprint delta across every accepted run and device.
2. Multiply by `1.25`.
3. Round up to the next `100,000,000` bytes.
4. Add a fixed `750,000,000` byte reserve.
5. Require the profile's minimum physical RAM and the resulting process headroom before native construction.
6. After load, require at least the fixed reserve from one new process-headroom sample.

When replacing an already loaded model, native unload must finish and a five-second recovery window must complete before the single admission sample. There is no arbitrary fallback headroom. A pre-teardown shortfall inside the one-gigabyte transient window is estimate noise rather than proof of OOM, so the switch path attempts teardown and lets the post-teardown gates measure reality (restoring the prior model on failure); wider shortfalls still refuse with the resident model preserved.

## Current evidence

| Profile | Runtime shape | Evidence | Production |
| --- | --- | --- | --- |
| Gemma 4 E2B vision | projector required, context 4096, batch 512, microbatch 128 | Accepted on target `00008140-000178A1362B001C`: five measured cycles, 20 text prompts, five image turns, background/foreground, peak delta 798,559,232 bytes, required headroom 1,750,000,000 bytes | Validated |
| Gemma 4 E4B text calibration | no projector, context 512, batch 256, microbatch 64, mmap enabled, CPU settings unchanged | Unvalidated | Disabled (calibration only) |
| Gemma 4 E4B vision | projector required, context 4096, batch 512, microbatch 128, CPU-pinned | Unvalidated | Estimated (refused on this device: 4.55 GB needed, ~3.54 GB is this app's ceiling) |
| Llama 3.2 3B text | context 4096, batch 512, microbatch 128 | Unvalidated | Estimated |
| Llama 3.2 3B text, Metal offload | as above, full Metal offload | Unvalidated | Estimated |
| Gemma 4 E2B vision, Metal offload | as above, full Metal offload | Unvalidated | Estimated (validated CPU shape is served instead) |
| Gemma 4 E4B text | no projector, context 512, batch 256, microbatch 64, CPU-pinned | Unvalidated | Estimated (measured load + one generation, 2026-11-12) |
| LFM 2.5 1.2B / 2.6B, Qwen 3.5 2B / 0.8B, Bonsai 8B / 4B (CPU and Metal) | `curatedText4K`: context 4096, batch 512, microbatch 128 | Unvalidated | Estimated |

When one model has several shapes, the strongest evidence wins before the faster shape does: a validated CPU shape keeps serving instead of being displaced by an estimated Metal shape. Once a Metal shape earns experimental or validated evidence it selects automatically with no code change.

The retained E2B load-only delta remains 790,334,488 bytes for diagnostic history; production admission uses the larger accepted full-workload peak of 798,559,232 bytes. Configured context, batch, and microbatch values are specified runtime controls, not measurements. Evidence is retained under `test-output/memory-diagnostic-e2b-round1-warm-20260726T165800Z/`.

## Measured load matrix (2026-11-11 and 2026-11-12, iPhone 16, 8 GB)

A DEBUG-only probe loaded every catalog row through the real lifecycle path,
sampled the physical footprint before and after, ran one short generation, and
unloaded. This is a **load-only** delta, so it proves the load and gives a
lower bound on residency; it is not a full-workload peak and must not be written
into `measuredFullWorkloadPeakDeltaBytes`.

Reference device headroom: 3,512,351,848 bytes. Process ceiling (`available +
footprint`, the app's jetsam limit): ~3.54 GB. Deltas are physical-footprint
bytes.

| Model | Shape selected | Load | Load delta | One generation |
| --- | --- | --- | --- | --- |
| llama3.2-3b-q4 | `llama32-3b-text-metal-p1` | loaded, 4.5 s | 533,743,440 | `OK` |
| gemma-4-e2b-q4 | `gemma4-e2b-vision-p1` (validated CPU) | loaded, 5.0 s | 787,369,032 | `OK.` |
| gemma-4-e4b-q4-text | `gemma4-e4b-text-p1` (CPU-pinned) | loaded, 6.7 s | 83,349,248 | `OK.` in 6.0 s |
| gemma-4-e4b-q4 | `gemma4-e4b-vision-p1` (CPU-pinned) | refused: 4.55 GB needed, 3.54 GB is the app's ceiling | — | — |
| lfm2.5-1.2b-q4 | `lfm2.5-1.2b-q4-text-metal-ctx4096-p1` | loaded, 1.2 s | 51,380,800 | `OK` |
| lfm2.5-2.6b-q4 | `lfm2.5-2.6b-q4-text-metal-ctx4096-p1` | loaded, 2.5 s | 93,504,736 | thinking block, 51 chars |
| qwen3.5-2b-q4 | `qwen3.5-2b-q4-text-metal-ctx4096-p1` | loaded, 0.3 s | 93,012,952 | `OK` |
| qwen3.5-0.8b-q4 | `qwen3.5-0.8b-q4-text-metal-ctx4096-p1` | loaded, 0.9 s | -18,022,040 | `OK` |
| bonsai-8b-q1 | `bonsai-8b-q1-text-metal-ctx4096-p1` | loaded, 0.3 s | 616,547,576 | `Okay.` |
| bonsai-4b-q1 | `bonsai-4b-q1-text-metal-ctx4096-p1` | loaded, 0.2 s | 615,793,480 | `OK.` |

Evidence runs: `20261111-090503`, `20261110-164905` (llama, E2B, E4B);
`20261112-134644` (the six lineup rows); `20261112-135235` (both E4B rows
after the CPU pin).

Two rows need a note rather than a number. `qwen3.5-0.8b-q4` reports a negative
delta because the before-load sample was taken while the previous row's context
was still being torn down; the load is real and the generation answered. The six
lineup rows answer on the same `curatedText4K` Metal shape llama3.2-3b-q4
answers on, at every size in the set.

The E2B measurement independently corroborates the retained validated profile:
a 787 MB load delta against the accepted 798,559,232-byte full-workload peak.

### Fixed 2026-11-12: E4B is pinned to CPU and the row answers

`gemma-4-e4b-q4-text` used to load on the Metal shape and then fail every
decode (below). Both E4B runtime presets now pin `gpuLayers: 0`, the two E4B
Metal profiles are deregistered, and the row loads on `gemma4-e4b-text-p1` in
6.7 s and answers in 6.0 s on the measured device. CPU residency rides the same
mmap path the estimate assumes (~base/3, 83 MB touched), so admission admits it
with ~330 MB to spare against the app ceiling.

### Finding: full Metal offload of a 5.3 GB base fails at decode

`gemma-4-e4b-q4-text` **loads** on the Metal shape and then fails every decode:

```
error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)
ggml_metal_synchronize: error: command buffer 0 failed with status 5
ggml_metal_graph_compute: backend is in error state from a previous command buffer failure
llama_decode: failed to decode, ret = -3
```

The process footprint after load was 74 MB, so the weights are in GPU memory
that process-headroom admission cannot see. `ModelConfiguration.autoGpuLayers`
tiers on device RAM alone (`>= 8 GB` gets full offload) and never on the
model's weight size, so a 5.34 GB base is fully offloaded on an 8 GB iPhone and
the Metal allocation fails at the first decode. E2B (3.43 GB base) offloads
fine on the same device, so the boundary sits between those two sizes.

### Decision: Gemma 4 E4B vision stays refused (option 3)

Measured reason, not a preference:

1. Both E4B vision shapes are `.estimated`, so ranking prefers the faster
   (Metal) one, and the Metal workload dies on the allocation above instead of
   producing evidence.
2. The CPU vision shape is refused on the estimate (4.55 GB against a ~3.54 GB
   app ceiling), so no shape can serve on this device today.

The path that can make the row loadable, in order:

1. ~~Give the E4B rows a CPU-only runtime shape (`gpuLayers: 0`) and remove the
   E4B Metal profiles.~~ **Done 2026-11-12.** The text row loads and answers on
   CPU; the vision row now has exactly one shape and one honest reason.
2. Run the retained CPU vision calibration (`--model e4b --profile vision`).
3. Write `measuredFullWorkloadPeakDeltaBytes` + `.validated`, after which the
   validated CPU shape serves automatically — if the measured peak puts the
   required headroom under the app ceiling. A measured E4B vision peak would
   have to come in under ~2.2 GB for `peak x 1.25 + 750MB` to fit inside 3.54 GB.

Until then the row keeps its `.estimated` tier and is refused at load — and the
surface now says so before the download, using the admission verdict itself
rather than a second heuristic (`ModelDetailView.runtimeSection`).

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
