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
| Chat shim | `Packages/swift-llama-cpp/Native/ZiroChat.{h,cpp}` |
| Checkout cache | `~/Library/Caches/ziroedge-llama/<tag>/llama.cpp` |

Prior pin was `b9821`. It shipped no simulator slice in the release asset used
here and was the wrong integration base to keep patching.

## Why this artifact is built locally, not downloaded

Upstream's release asset is built by upstream's `build-xcframework.sh`, which
sets `LLAMA_BUILD_COMMON=OFF`. That default is the reason the release asset
cannot do two things this app needs:

1. **Honor template kwargs.** `llama_chat_apply_template` (the C API) is a
   heuristic formatter over a fixed template list with no kwargs, so
   `enable_thinking` is silently ignored.
2. **Split reasoning from the answer.** The parser that produces
   `reasoning_content` also lives in `common/chat.cpp`.

Linking upstream's own jinja engine (`common/chat.cpp` and its `jinja/` and
`peg-parser/` sources) is therefore what makes thinking control possible at all.
That is the whole reason this repository builds its runtime instead of consuming
the release `.xcframework` by URL + checksum. The build is not a custom
integration: no upstream flag diverges from its defaults and the pin is exact.
It is upstream's script with three additions, listed under "Build divergences".

## Rebuild

```bash
./Scripts/build-llama-xcframework.sh              # uses the pin above
LLAMA_TAG=b12435 ./Scripts/build-llama-xcframework.sh
LLAMA_KEEP_SRC=0 ./Scripts/build-llama-xcframework.sh   # drop build trees
```

The script runs upstream's own `build-xcframework.sh ios-sim ios-device`, which
needs **cmake 3.28+** and takes about 25–35 minutes on an 8-core Mac. It unsets
`CC`/`CXX` first: Homebrew toolchain exports make CMake's Xcode generator fail
with `The C compiler identification is unknown`.

Do not hand-assemble slices. If a future release publishes a device-only
XCFramework, build both slices here; the simulator test target needs
`ios-arm64_x86_64-simulator`.

The script finishes by checking each slice for the chat symbols and for
`Headers/ZiroChat.h`. A missing symbol fails the build there rather than at the
app's next link.

### Build divergences (all applied to the checkout, never to the app)

| Divergence | Why |
| --- | --- |
| `LLAMA_BUILD_COMMON=ON` | Builds `libllama-common.a` — the jinja engine and reply parsers. |
| `libllama-common{,-base}.a` and `libcpp-httplib.a` added to the framework link | `llama-common` links `cpp-httplib` PRIVATE, so those objects are not inside `libllama-common.a`; the link fails without the archive. |
| `ZiroChat.cpp` added to the `llama-common` target, `ZiroChat.h` copied into each slice's `Headers/` | Upstream's umbrella module map exposes every header in `Headers/`, so `import llama` then exposes the chat surface. |

The patch is idempotent per addition and asserts each marker afterwards: a
retained checkout that skips one addition fails at link time, which costs a full
rebuild to discover.

## C-API deltas handled in the wrapper

Moving `b9821 → b12000` changed three call sites. Record the next ones here.

| Change | Fix |
| --- | --- |
| `llama_model_params.use_mmap` / `use_mlock` removed | `load_mode = LLAMA_LOAD_MODE_MMAP` (or `NONE`) |
| `llama_sampler_init_penalties` gained a leading `n_vocab` | `llama_vocab_n_tokens(vocab)` |
| `mtmd_helper_bitmap_init_from_buf` gained a trailing `mtmd_helper_init_opt` | `mtmd_helper_init_opt_default()` |

`llama_context_params.flash_attn_type` and the sampler constructors the engine
uses (`greedy`, `temp`, `top_k`, `top_p`, `dist`, `penalties`) are unchanged.

## Prompt path: one rule, two formatters

There is exactly one prompt path — the model's own chat template — and two ways
to render it, chosen by the row's declaration:

| Row declares | Renderer | Kwargs | Reasoning split |
| --- | --- | --- | --- |
| nothing (`chatTemplateName == nil`) | jinja (`common_chat_templates_apply`) | yes | yes |
| a built-in family name (`chatTemplateName: "gemma"`) | heuristic (`llama_chat_apply_template`) | no | no |

The second row exists because upstream's family templates for GGUF files that
ship none are C++ builders, not template strings — there is no jinja source to
hand the engine. Exactly one catalog row needs it: the Gemma 4 E2B GGUF carries
no `tokenizer.chat_template` (35 KVs, none of them a template), so it declares
`chatTemplateName: "gemma"`.

A row that declares a built-in name **cannot** carry a thinking policy: the
heuristic formatter has no kwargs, so the load gate refuses it with
`chat-template-thinking-unsupported` instead of loading a model that would
reason forever. That is the same rule as `chat-template-missing`, applied to the
switch instead of the syntax.

Nothing is hand-formatted. The `.gemma` and `.raw` Swift formatters were removed
when the runtime moved to `apply_template`; wrong control tokens degrade output
measurably.

## Thinking control

A row declares what it wants done with the model's own reasoning
(`AIModel.thinking`, `ChatThinkingPolicy`):

| Policy | Template input | Meaning |
| --- | --- | --- |
| `.templateDefault` | `-1` (absent) | Keep the template's own default. Every shipped row. |
| `.disabled` | `enable_thinking = false` | Suppress the reasoning block. |
| `.enabled` | `enable_thinking = true` | Reason before answering. |

`ChatThinkingPolicy.requiresTemplateSupport` is what the load gate checks: an
explicit policy needs a template that reads the variable
(`common_chat_templates_support_enable_thinking`). A model that reasons with no
switch is a blocked row, not a catalog row.

The old `/no_think` experiment is dead. It was a suffix appended to the user
text, which the heuristic formatter passed through as plain content; the Bonsai
8B re-test (2026-11-16, run `20261116-120958`) showed the model still emitted an
unclosed `<think>` preamble on all three prompts. Thinking control now goes
through template inputs, never string surgery on the reply.

## Reasoning split

The reply is parsed incrementally by the template's own parser
(`common_chat_session::feed`), which reports `content` and `reasoning_content`
separately. `ReplySplitter` emits only `content` deltas, so the chat surface
never renders a thinking block: while the model reasons the visible delta is
legitimately empty, which the existing "still thinking" indicator already
reads correctly.

Evidence the split happened is one console line per turn —
`Reply split reasoningCharacters=… termination=…` — which the device
verification lane captures. Reply text is never logged.

If the parser throws, the splitter degrades to raw text: a broken parser must
not swallow an answer.

A template's own stop strings (`additional_stops`) are merged into the caller's
stops when the prompt is rendered. Without them a turn can run past the point
the model meant to end.

## Load preflight

`LlamaEngine.verifyLoad()` decodes one token and samples one token before
`InferenceService` commits a load. This catches the upstream class where native
construction succeeds but the first decode dies (fatal Metal OOM), which
otherwise leaves a model advertised as loaded while every request fails. The KV
is cleared afterwards, so the first real turn starts empty.

`LlamaEngine.chatTemplateGate()` runs after it and returns one of three
verdicts, each with its own refusal copy:

| Verdict | Diagnostic | Meaning |
| --- | --- | --- |
| `.ready` | — | Prompt it. |
| `.missing` | `chat-template-missing` | No template the runtime can render. Upstream's ChatML fallback does not count: it is not this model's syntax. |
| `.thinkingUnsupported` | `chat-template-thinking-unsupported` | The row asked for a thinking policy its template ignores. |

## Upgrade checklist

1. `LLAMA_TAG=<new> ./Scripts/build-llama-xcframework.sh` — the script re-checks
   that upstream's `LLAMA_BUILD_COMMON` default, link list, and
   `llama-common` source list are still where the patch expects them.
2. `xcodebuild build-for-testing -scheme ZiroEdge -destination 'platform=iOS Simulator,id=<sim>'`
3. Device Debug build + install (`verify.sh launch -- --uitesting`).
4. Re-verify **every catalog row** with the model-usage sweep. The runtime backs
   all of them; a green unit suite proves none of it.
5. Re-check every thinking policy against reality: a row whose template stops
   reporting `supports_thinking` is refused at load, which is visible in the
   sweep as `chat-template-thinking-unsupported`.

## Editor support for the shim

`Native/ZiroChat.cpp` is compiled by the build script, not by the Xcode project,
so nothing tells SourceKit where `chat.h` and `llama.h` are. The script appends
its include paths to the machine-local `.compile` database, which is what makes
the file resolve in the editor. Without that entry a single-file check sees
`'llama.h' file not found` and reports the cascade as dozens of unknown-type
errors; a real `clang++ -fsyntax-only` with those include paths exits 0.
