//
// ZiroChat.h
// SwiftLlama — C surface over llama.cpp's jinja chat engine
//
// `llama_chat_apply_template` (llama.h) is a heuristic formatter over a fixed
// template list. It cannot accept template kwargs, so it cannot honor
// `enable_thinking`, and it cannot split a reply into content and
// `reasoning_content`. Upstream's real engine lives in `common/chat.cpp`
// (minja + the PEG reply parsers) and is what llama-server uses.
//
// This header is the whole contract the app depends on: opaque handles, plain
// C types, no C++ structs crossing the boundary. The implementation
// (`ZiroChat.cpp`) is built from the pinned upstream checkout and linked into
// the same dynamic framework as llama, so template rendering and reply parsing
// always match the runtime they run on.
//
// Lifecycle: every `_create` returns an owned handle that the caller must
// destroy. Strings returned by `_prompt`/`_content`/`_reasoning` are borrowed
// from the handle and stay valid until the next call on it or its destruction.
//

#ifndef ZIRO_CHAT_H
#define ZIRO_CHAT_H

#include <stddef.h>

// Only an opaque model handle crosses this boundary. Forward-declaring it keeps
// the header consumable on its own (C, C++, and Swift's importer) instead of
// dragging in the whole llama.h surface.
struct llama_model;

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ziro_chat_templates ziro_chat_templates;
typedef struct ziro_chat_session ziro_chat_session;

/// One conversation turn, borrowed for the duration of the create call.
typedef struct ziro_chat_turn {
    /// "system", "user", "assistant", or a tool role the template understands.
    const char * role;
    /// NUL-terminated UTF-8 message body.
    const char * content;
} ziro_chat_turn;

/// Sentinel for "leave the template's own default in place".
#define ZIRO_CHAT_THINKING_DEFAULT (-1)

// MARK: - Templates

/// Parse the model's embedded `tokenizer.chat_template` with the jinja engine.
/// Returns NULL when the GGUF carries no template or when minja cannot parse
/// it — a refusal the caller must treat as "this row cannot be prompted",
/// never as "fall back to a heuristic formatter".
ziro_chat_templates * ziro_chat_templates_create(const struct llama_model * model);

void ziro_chat_templates_destroy(ziro_chat_templates * templates);

/// Whether this template reads `enable_thinking` at all. A row that reasons but
/// whose template ignores the switch is unblockable, so a caller that wants to
/// turn thinking off must check this first.
int ziro_chat_templates_supports_thinking(const ziro_chat_templates * templates);

/// The template source the engine parsed. Borrowed; for diagnostics and for
/// proving the load gate refused the right thing.
const char * ziro_chat_templates_source(const ziro_chat_templates * templates);

/// Whether the template came from the GGUF rather than upstream's ChatML
/// fallback. A GGUF without a template is a row that must declare one.
int ziro_chat_templates_was_explicit(const ziro_chat_templates * templates);

// MARK: - Session

/// Render `turns` into a prompt and prepare the matching reply parser.
/// `enable_thinking` takes `ZIRO_CHAT_THINKING_DEFAULT`, 0, or 1.
/// Returns NULL when rendering throws (a template that needs a variable the
/// caller does not supply), which is a load-time refusal, not a retry.
ziro_chat_session * ziro_chat_session_create(
    const ziro_chat_templates * templates,
    const struct llama_model * model,
    const ziro_chat_turn * turns,
    size_t turn_count,
    int add_generation_prompt,
    int enable_thinking);

void ziro_chat_session_destroy(ziro_chat_session * session);

/// The rendered prompt, ready for `llama_tokenize`. Borrowed.
const char * ziro_chat_session_prompt(const ziro_chat_session * session);

/// Template-derived stops the prompt expects the runtime to honor. The engine
/// adds these to the sampler's stop sequence; a template that declares none
/// returns 0. Without them a chatty template never stops on its own turn end.
size_t ziro_chat_session_stop_count(const ziro_chat_session * session);

/// Stop string at `index`, borrowed. Empty string when out of range.
const char * ziro_chat_session_stop(const ziro_chat_session * session, size_t index);

/// Human-readable parser family, for diagnostics only. Borrowed.
const char * ziro_chat_session_format(const ziro_chat_session * session);

/// Append one generated text piece and re-parse the accumulated reply.
/// Incremental: call once per decoded piece, in order. Returns 0 on success and
/// non-zero when the parser threw, in which case the reply is left as raw text.
int ziro_chat_session_feed(ziro_chat_session * session, const char * text, size_t length);

/// Announce end of generation so the final parse can close open blocks.
int ziro_chat_session_finish(ziro_chat_session * session, const char * text, size_t length);

/// Reply body with any reasoning block removed. Borrowed, valid until the next
/// `feed`/`finish`/destroy. Empty string before the first feed.
const char * ziro_chat_session_content(const ziro_chat_session * session);

/// Reasoning body (`reasoning_content`). Borrowed, same lifetime rules.
const char * ziro_chat_session_reasoning(const ziro_chat_session * session);

#ifdef __cplusplus
}
#endif

#endif /* ZIRO_CHAT_H */
