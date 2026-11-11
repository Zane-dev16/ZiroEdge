# Runtime memory profiles and calibration

Runtime memory admission is independent of GGUF and projector download sizes. Artifact sizes are used only for download, integrity, and storage UI.

## GPU tiering

Runtime is auto-tiered: full Metal GPU offload on 8GB+ devices, CPU-only below (`ModelConfiguration.autoGpuLayers()`). Each tier is a separate runtime shape with independent evidence — an uncalibrated Metal shape fails closed to CPU instead of refusing a load CPU could serve.

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
| Gemma 4 E4B vision | projector required, context 4096, batch 512, microbatch 128 | Unvalidated | Estimated |
| Llama 3.2 3B text | context 4096, batch 512, microbatch 128 | Unvalidated | Estimated |
| Llama 3.2 3B text, Metal offload | as above, full Metal offload | Unvalidated | Estimated |
| Gemma 4 E2B vision, Metal offload | as above, full Metal offload | Unvalidated | Estimated (validated CPU shape is served instead) |
| Gemma 4 E4B text, Metal offload | as above (512/256/64), full Metal offload | Unvalidated | Estimated |
| Gemma 4 E4B vision, Metal offload | as above, full Metal offload | Unvalidated | Estimated |
| LFM 2.5 1.2B / 2.6B, Qwen 3.5 2B / 0.8B, Bonsai 8B / 4B (CPU and Metal) | `curatedText4K`: context 4096, batch 512, microbatch 128 | Unvalidated | Estimated |

When one model has several shapes, the strongest evidence wins before the faster shape does: a validated CPU shape keeps serving instead of being displaced by an estimated Metal shape. Once a Metal shape earns experimental or validated evidence it selects automatically with no code change.

The retained E2B load-only delta remains 790,334,488 bytes for diagnostic history; production admission uses the larger accepted full-workload peak of 798,559,232 bytes. Configured context, batch, and microbatch values are specified runtime controls, not measurements. Evidence is retained under `test-output/memory-diagnostic-e2b-round1-warm-20260726T165800Z/`.

## Measured load matrix (2026-11-11, iPhone 16, 8 GB)

A DEBUG-only probe loaded every catalog row through the real lifecycle path,
sampled the physical footprint before and after, ran one short generation, and
unloaded. This is a **load-only** delta, so it proves the load and gives a
lower bound on residency; it is not a full-workload peak and must not be written
into `measuredFullWorkloadPeakDeltaBytes`.

Reference device headroom: 3,512,351,848 bytes. Deltas are physical-footprint
bytes.

| Model | Shape selected | Load | Load delta | One generation |
| --- | --- | --- | --- | --- |
| llama3.2-3b-q4 | `llama32-3b-text-metal-p1` | loaded, 4.5 s | 533,743,440 | `OK` |
| gemma-4-e2b-q4 | `gemma4-e2b-vision-p1` (validated CPU) | loaded, 5.0 s | 787,369,032 | `OK.` |
| gemma-4-e4b-q4-text | `gemma4-e4b-text-metal-p1` | loaded, 5.3 s | 74,075,904 | **failed** |
| gemma-4-e4b-q4 | `gemma4-e4b-vision-metal-p1` | refused by admission (needs 4.24 GB, 3.26 GB spare) | — | — |

The E2B measurement independently corroborates the retained validated profile:
a 787 MB load delta against the accepted 798,559,232-byte full-workload peak.

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

1. Calibrating the vision shape today would exercise the **Metal** shape — both
   E4B vision shapes are `.estimated`, so ranking prefers the faster one — and
   the workload would die on the Metal allocation above instead of producing
   evidence.
2. The CPU vision shape is refused on the estimate (4.55 GB), so no shape can
   serve on this device today.

The path that can make the row loadable, in order:

1. Give the E4B rows a CPU-only runtime shape (`gpuLayers: 0`) and remove the
   E4B Metal profiles that would otherwise claim the offload shape.
2. Run the retained CPU vision calibration (`--model e4b --profile vision`).
3. Write `measuredFullWorkloadPeakDeltaBytes` + `.validated`, after which the
   validated CPU shape serves automatically.

Until then the row keeps its `.estimated` tier and is refused at load. Its
surface copy still reads "Ready to use" and its download is still offered on a
device that cannot load it; that copy is the next honest-copy item, not a
memory-policy change.

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
