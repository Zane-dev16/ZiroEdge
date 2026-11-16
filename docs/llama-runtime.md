# llama.cpp runtime

ZiroEdge links a prebuilt `llama.xcframework` through the local Swift package
`Packages/swift-llama-cpp`. The binary is gitignored; the recipe that produces
it is not.

## Pin

| | |
| --- | --- |
| Upstream tag | **`b12000`** (ggml-org/llama.cpp) |
| Slices | `ios-arm64`, `ios-arm64_x86_64-simulator` |
| Build script | `Scripts/build-llama-xcframework.sh` |
| Swift wrapper | `Packages/swift-llama-cpp/Sources/SwiftLlama/` |

Prior pin was `b9821`. It shipped no simulator slice in the release asset used
here and was the wrong integration base to keep patching.

## Rebuild

```bash
./Scripts/build-llama-xcframework.sh              # uses the pin above
LLAMA_TAG=b12435 ./Scripts/build-llama-xcframework.sh
LLAMA_KEEP_SRC=1 ./Scripts/build-llama-xcframework.sh
```

The script runs upstream's own `build-xcframework.sh ios-sim ios-device`, which
needs **cmake 3.28+**. It unsets `CC`/`CXX` first: Homebrew toolchain exports
make CMake's Xcode generator fail with `The C compiler identification is
unknown`.

Do not hand-assemble slices. If a future release publishes a device-only
XCFramework, build both slices here; the simulator test target needs
`ios-arm64_x86_64-simulator`.

## C-API deltas handled in the wrapper

Moving `b9821 → b12000` changed three call sites. Record the next ones here.

| Change | Fix |
| --- | --- |
| `llama_model_params.use_mmap` / `use_mlock` removed | `load_mode = LLAMA_LOAD_MODE_MMAP` (or `NONE`) |
| `llama_sampler_init_penalties` gained a leading `n_vocab` | `llama_vocab_n_tokens(vocab)` |
| `mtmd_helper_bitmap_init_from_buf` gained a trailing `mtmd_helper_init_opt` | `mtmd_helper_init_opt_default()` |

`llama_context_params.flash_attn_type` and the sampler constructors the engine
uses (`greedy`, `temp`, `top_k`, `top_p`, `dist`, `penalties`) are unchanged.

## Template formatting: what `apply_template` is not

`llama_chat_apply_template` is a **heuristic formatter over a fixed template
list**, not a Jinja engine (upstream's own header says so). Consequences the app
lives with:

- Detected families (Gemma, Llama 3, ChatML/Qwen, …) render correctly.
- Template kwargs do not exist. `enable_thinking=false`, Qwen's `/no_think`
  suffix, and reasoning-budget switches are **not** honored: the simplified
  formatter ignores them. A model that reasons still reasons.
- Upstream's real jinja path lives in `common/chat.cpp`
  (`common_chat_apply_template` / `common_chat_parse`), which this package does
  not link. Adding it is the prerequisite for any reasoning-model row.

Because of this, ZiroEdge has exactly one prompt path: the model's embedded
template. The old hand-rolled `.gemma` and `.raw` formatters were removed —
wrong control tokens degrade output measurably. A model whose template cannot
be rendered is refused at load with `chat-template-missing`; there is no
fallback syntax.

One catalog row needs a declared template. The Gemma 4 E2B GGUF ships **no**
`tokenizer.chat_template` at all (35 KVs, none of them a template), so the row
sets `chatTemplateName: "gemma"`. The runtime still renders every turn from its
built-in `gemma` template; the declaration only selects which family template to
use. Without it the load gate correctly refused the row.

The Bonsai 8B `/no_think` re-test (2026-11-16, run `20261116-120958`) proved the
limit on hardware: the suffix reached the prompt and the model still emitted an
unclosed `<think>` preamble on all three prompts. The row stays cut.

## Load preflight

`LlamaEngine.verifyLoad()` decodes one token and samples one token before
`InferenceService` commits a load. This catches the upstream class where
native construction succeeds but the first decode dies (fatal Metal OOM),
which otherwise leaves a model advertised as loaded while every request fails.
The KV is cleared afterwards, so the first real turn starts empty.

## Upgrade checklist

1. `LLAMA_TAG=<new> ./Scripts/build-llama-xcframework.sh`
2. `xcodebuild build-for-testing -scheme ZiroEdge -destination 'platform=iOS Simulator,id=<sim>'`
3. Device Debug build + install (`verify.sh launch -- --uitesting`).
4. Re-verify **every catalog row** with the model-usage sweep. The runtime backs
   all of them; a green unit suite proves none of it.
