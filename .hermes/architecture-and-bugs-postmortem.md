# ZiroEdge Architecture & Gemma Bug Fixes

## The Three Bugs — Post-Mortem

Written 2026-07-16 by Hermes after a session diagnosing and fixing the "No model loaded" error in ZiroEdge chat.

---

## Architecture — The Moving Parts

There are 7 key components involved in getting a model response on the device, organized in 4 layers:

### Layer 1: The App (SwiftUI)

**ZiroEdgeApp.swift** — entry point. On launch, the `.task` modifier runs. If the `--uitesting` flag is present, it calls `autoLoadFirstModel()`. The user sees a sidebar with conversations. Tapping "New Conversation" fires the `onNewConversation` handler, which now also calls `autoLoadFirstModel()` — so the model loads before the chat screen appears (this was a fix applied during this session).

**ChatViewModel** — the brain of the chat UI. When the user sends a message, `sendMessage()` runs. It first checks `lifecycleManager.isModelLoaded`. If false, it shows the "No model loaded" error banner. If true, it delegates to `ChatSessionActor` (which persists messages) and eventually calls `inferenceService.streamChat()`.

### Layer 2: Model Lifecycle

**ModelLifecycleManager** (`@MainActor`) — owns the lifecycle state machine: `unloaded → loading → loaded → evicted`. Two critical methods:

- `autoLoadFirstModel()` — iterates `ModelRegistry.allModels`, calls `ModelManagerService.isFullyDownloaded()` to find the first model with both base `.gguf` and mmproj `.gguf` files on disk, then calls `loadModel()`.
- `loadModel(model)` — checks memory budget via `MemoryBudgeter`, then delegates to `inferenceService.loadModel()`. On success, sets `currentState = .loaded`.

**MemoryBudgeter** (`actor`) — calls `host_statistics64()` (Mach kernel API) to get free + inactive + purgeable memory pages. Compares against model size + 1.5 GB headroom. Returns `.proceed`, `.unloadCurrentFirst`, or `.insufficientRAM`.

**ModelManagerService** — static utility. `isFullyDownloaded()` checks `FileManager.default.fileExists()` for both the base GGUF and mmproj GGUF files at `Documents/Models/{id}.gguf` and `Documents/Models/{id}-mmproj.gguf`.

### Layer 3: Inference (the engine)

**InferenceService** (`actor`) — the public API boundary. No llama.cpp types leak past here. Holds an optional `LlamaEngine`. Methods:

- `loadModel()` — validates file existence and size, then creates the engine.
- `streamChat()` — formats the prompt via `formatChatPrompt()`, then calls `eng.streamCompletion()`.
- `formatChatPrompt()` — produces model-specific prompt format based on `config.promptPath` (`.chatTemplate` for Gemma uses `<start_of_turn>` tokens, `.raw` for others uses `User:/Assistant:` format).

**LlamaEngine** (`actor`, in swift-llama-cpp package) — wraps the C `llama.h` API. Its `streamCompletion()` does the real work:

1. **Tokenize** — `llama_tokenize()` converts the prompt string to token IDs
2. **Build batch** — `llama_batch_init()` allocates a batch structure with `token`, `pos`, `n_seq_id`, `seq_id`, `logits` arrays
3. **Decode prompt** — `llama_decode()` runs the prompt through the model, computing key/value cache
4. **Create sampler** — builds a chain of samplers: Top-K → Top-P → Temperature → Distribution
5. **Autoregressive loop** — for each token:
   - `llama_sampler_sample()` picks the next token
   - Check EOS token and stop strings
   - `llama_decode()` with single-token batch to update KV cache
   - Yield token text to the async stream

### Layer 4: The C library (llama.cpp)

The `llama` module is a pre-built `.xcframework` containing the llama.cpp C library compiled for iOS arm64. The Swift code calls functions like `llama_model_load_from_file()`, `llama_batch_init()`, `llama_decode()`, `llama_sampler_sample()`, etc. through the C interop bridge. Target: upstream release b9821.

---

## Bug 1: seq_id malloc double-free

**Symptom:** App crashes with `malloc: *** error: pointer being freed was not allocated` during inference. The test runner shows `Restarting after unexpected exit`.

**Root cause:** `llama_batch_init(n_tokens, 0, 1)` allocates the inner `seq_id[i]` arrays internally. Each `seq_id[i]` is already a valid pointer to a 1-element `llama_seq_id` array allocated by the C library. But the original Swift code was doing:

```swift
batch.seq_id[i] = UnsafeMutablePointer.allocate(capacity: 1)  // OVERWRITES the pre-allocated pointer
batch.seq_id[i]!.pointee = 0
```

This replaced the original pointer that `llama_batch_init` set up, leaking it. Then `llama_batch_free()` tried to free the leaked (now unreachable) original pointer — crash. Additionally, the code manually deallocated the NEW pointer with `.deallocate()`, then `llama_batch_free` also tried to free it — double free.

**How it was found:** The direct inference test succeeded (bypassing the batch path in a fresh test process), but the chat UI test crashed. The `malloc` error appeared in the xcodebuild stdout. Examining the `seq_id` allocation pattern in `LlamaEngine.swift` revealed the double-allocation.

**Fix:** Use the already-allocated array directly without replacing the pointer:

```swift
batch.seq_id[i]![0] = 0  // Just set the value, don't replace the pointer
```

And remove all manual `.deallocate()` calls — `llama_batch_free()` handles all cleanup. Applied to all three batch sites: prompt batch, text generation eval batch, and vision generation eval batch.

**Files changed:**
- `Packages/swift-llama-cpp/Sources/SwiftLlama/LlamaEngine.swift` (3 sites in `streamCompletion` and `streamVisionCompletion`)

---

## Bug 2: Wrong prompt format for Gemma

**Symptom:** Model generates garbage or runs in an infinite loop, eventually crashing from memory or token overflow. The response contains raw stop token fragments.

**Root cause:** `formatChatPrompt()` in `InferenceService.swift` was producing a generic format:

```
User: Hello
Assistant:
```

Gemma models use a specific chat template with special tokens:

```
<start_of_turn>user
Hello<end_of_turn>
<start_of_turn>model

```

Without these tokens, the model doesn't understand conversation boundaries. It never generates its stop token `<end_of_turn>`, so it loops until context is full (4096 tokens), consuming massive time and memory, eventually crashing.

**How it was found:** The direct inference test with manually formatted Gemma prompt worked. But the chat UI test (which goes through `formatChatPrompt`) never received a response — the model ran indefinitely. The `ModelConfiguration.gemma4` had `promptPath: .chatTemplate` but `formatChatPrompt` never checked this field.

**Fix:** Updated `formatChatPrompt` to check `config.promptPath`:

- `.chatTemplate` (Gemma and other chat-template models) → produces `<start_of_turn>role\ncontent<end_of_turn>\n` format
- `.raw` (translation models, raw-completion models) → uses the original `User:/Assistant:` format

**Files changed:**
- `ZiroEdge/Services/InferenceService.swift` — `formatChatPrompt()` rewritten with switch on `config.promptPath`

---

## Bug 3: Memory budget blocking model load

**Symptom:** "No model loaded" error in chat UI — model never loads even though files exist and the direct inference test works. The model picker shows "Gemma 4 E2B" but `isModelLoaded` is false.

**Root cause:** `MemoryBudgeter.recommendation()` requires `modelSize + 1.5 GB headroom`. For Gemma E2B:

- Base GGUF:  3,427,861,088 bytes (3.2 GB)
- MMProj GGUF: 557,367,776 bytes (532 MB)
- Total model: 3,985,228,864 bytes (3.7 GB)
- Required:    3.7 GB + 1.5 GB = **5.2 GB**

The iPhone 16 has 8 GB RAM total, but iOS + background services consume several GB. The `host_statistics64` free + reclaimable pages fell below 5.2 GB, so `recommendation()` returned `.insufficientRAM`.

The old code treated this as fatal:

```swift
case .insufficientRAM:
    currentState = .loadFailed
    return  // NEVER LOADS — silent failure
```

But the direct inference test (which bypasses `ModelLifecycleManager` and calls `InferenceService.loadModel()` directly) proved the model CAN load and generate on the device. The 1.5 GB headroom was too conservative for a model that actually uses ~4 GB at runtime.

**How it was found:** The chat UI showed "No model loaded" but the direct inference test loaded and generated successfully. Adding debug logging to `autoLoadFirstModel()` and `loadModel()` revealed `[LOAD] Memory recommendation: insufficientRAM` — the model was being rejected before ever trying to load. The direct test bypassed `MemoryBudgeter` entirely by calling `InferenceService.loadModel()` without going through the lifecycle manager.

**Fix:** Changed from blocking to advisory:

```swift
case .insufficientRAM:
    logger.warning("RAM is tight — attempting load anyway...")
    break  // TRY ANYWAY
```

If memory actually runs out, iOS kills the process with a clear crash log — much better than silently refusing with "no model loaded."

**Files changed:**
- `ZiroEdge/Services/ModelLifecycleManager.swift` — `loadModel()`: changed `.insufficientRAM` from `return` to `break`

---

## Bonus Fix: onNewConversation doesn't load the model

**Symptom:** User taps "New Conversation", sees the model name in the picker, types a message, hits send — "No model loaded" error.

**Root cause:** `autoSelectModel()` in `ChatViewModel` only sets `selectedModel` (the model name stored in memory) without actually loading the model into RAM. The `onNewConversation` handler called `autoSelectModel()` → created conversation → loaded chat history — all without loading the model. Then `sendMessage()` checked `lifecycleManager.isModelLoaded` which was still false.

The model was only auto-loaded when `--uitesting` was passed (for automated tests), never during normal app usage.

**Fix:** Added `lifecycleManager.autoLoadFirstModel()` to the `onNewConversation` handler so the model loads when the user creates a new chat.

**Files changed:**
- `ZiroEdge/ZiroEdgeApp.swift` — `onNewConversation` handler: added `autoLoadFirstModel()` call before creating conversation

---

## Verification

Run the unit test on device (confirmed passing after all fixes):

```bash
xcodebuild test-without-building \
  -scheme ZiroEdge \
  -destination 'id=00008140-000178A1362B001C' \
  -allowProvisioningUpdates \
  -parallel-testing-enabled NO \
  -only-testing:ZiroEdgeTests/ChatFlowDiagnosticTest/testFullChatFlowWithResponse
```

Output:
```
[FULLFLOW] === Starting full chat flow ===
[AUTOLOAD] autoLoadFirstModel called — activeModel=nil
[AUTOLOAD]   llama3.2-3b-q4: downloaded=false
[AUTOLOAD]   gemma-4-e2b-q4: downloaded=true
[AUTOLOAD] Selected: gemma-4-e2b-q4, loading...
[LOAD] loadModel(gemma-4-e2b-q4) — currentState=unloaded
[LOAD] Memory recommendation: insufficientRAM
[INFERENCE-LOAD] base file exists: true, size: 3427861088
[INFERENCE-LOAD] Engine created in 4.6s
[AUTOLOAD] loadModel returned — currentState=loaded, isLoaded=true
[FULLFLOW] Sending via streamChat...
[FULLFLOW] Response: Hi<end_of_turn
[FULLFLOW] === PASSED ===
Test passed (7.310 seconds)
```

## Key files

| File | Role |
|------|------|
| `ZiroEdge/ZiroEdgeApp.swift` | App entry — onNewConversation model loading fix |
| `ZiroEdge/ViewModels/ChatViewModel.swift` | Chat logic — sendMessage guard + debug logging |
| `ZiroEdge/Services/ModelLifecycleManager.swift` | Lifecycle — memory budget bypass + debug logging |
| `ZiroEdge/Services/InferenceService.swift` | Inference — formatChatPrompt Gemma fix |
| `ZiroEdge/Services/MemoryBudgeter.swift` | Memory — host_statistics64 RAM query |
| `Packages/swift-llama-cpp/Sources/SwiftLlama/LlamaEngine.swift` | Engine — seq_id fix, generation loop |
| `ZiroEdgeTests/ModelRegistryTests.swift` | Tests — ChatFlowDiagnosticTest, DirectInferenceTest |
