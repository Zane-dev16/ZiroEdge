//
// ZiroChat.cpp
// SwiftLlama — implementation of the C surface declared in ZiroChat.h
//
// Everything here is a thin, exception-free wrapper over upstream's
// `common/chat.cpp`. No formatting logic of our own: the prompt and the reply
// parser must be the ones llama-server would produce for this exact template.
//

#include "ZiroChat.h"

#include "chat.h"
#include "llama.h"

#include <string>
#include <vector>

struct ziro_chat_templates {
    common_chat_templates_ptr impl;
    std::string               source;
};

struct ziro_chat_session {
    common_chat_session      impl;
    std::string              prompt;
    std::vector<std::string> stops;
};

namespace {

std::vector<common_chat_msg> to_messages(const ziro_chat_turn * turns, size_t count) {
    std::vector<common_chat_msg> messages;
    messages.reserve(count);
    for (size_t index = 0; index < count; ++index) {
        common_chat_msg message;
        message.role    = turns[index].role == nullptr ? "user" : turns[index].role;
        message.content = turns[index].content == nullptr ? "" : turns[index].content;
        messages.push_back(std::move(message));
    }
    return messages;
}

}  // namespace

// MARK: - Templates

ziro_chat_templates * ziro_chat_templates_create(const struct llama_model * model) {
    if (model == nullptr) { return nullptr; }
    try {
        auto * templates = new ziro_chat_templates();
        // An empty override means "use the GGUF's own template". A GGUF without
        // one falls back to upstream's ChatML default, which is why the load gate
        // also asks whether the template was explicit.
        templates->impl   = common_chat_templates_init(model, "", "", "");
        templates->source = common_chat_templates_source(templates->impl.get(), "");
        return templates;
    } catch (...) {
        return nullptr;
    }
}

void ziro_chat_templates_destroy(ziro_chat_templates * templates) {
    delete templates;
}

int ziro_chat_templates_supports_thinking(const ziro_chat_templates * templates) {
    if (templates == nullptr) { return 0; }
    try {
        return common_chat_templates_support_enable_thinking(templates->impl.get()) ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

const char * ziro_chat_templates_source(const ziro_chat_templates * templates) {
    return templates == nullptr ? "" : templates->source.c_str();
}

int ziro_chat_templates_was_explicit(const ziro_chat_templates * templates) {
    if (templates == nullptr) { return 0; }
    return common_chat_templates_was_explicit(templates->impl.get()) ? 1 : 0;
}

// MARK: - Session

ziro_chat_session * ziro_chat_session_create(const ziro_chat_templates * templates,
                                             const struct llama_model *  model,
                                             const ziro_chat_turn *      turns,
                                             size_t                      turn_count,
                                             int                         add_generation_prompt,
                                             int                         enable_thinking) {
    if (templates == nullptr || model == nullptr) { return nullptr; }
    try {
        common_chat_templates_inputs inputs;
        inputs.messages              = to_messages(turns, turn_count);
        inputs.add_generation_prompt = add_generation_prompt != 0;
        inputs.use_jinja             = true;
        // Ask for the reasoning split: the parser records whether the reply
        // carries a reasoning block, which is what makes `reasoning_content`
        // available instead of leaving `<think>` inline in the body.
        inputs.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
        if (enable_thinking != ZIRO_CHAT_THINKING_DEFAULT) {
            inputs.enable_thinking = enable_thinking != 0;
        }

        auto * session = new ziro_chat_session{
            common_chat_session(templates->impl.get(),
                                llama_model_get_vocab(model),
                                inputs),
            {},
            {},
        };
        // Render once: `prompt()` returns a value, and the borrowed-string
        // contract in the header requires it to outlive the call.
        session->prompt = session->impl.prompt().str();
        session->stops  = session->impl.additional_stops();
        return session;
    } catch (...) {
        return nullptr;
    }
}

void ziro_chat_session_destroy(ziro_chat_session * session) {
    delete session;
}

const char * ziro_chat_session_prompt(const ziro_chat_session * session) {
    if (session == nullptr) { return ""; }
    return session->prompt.c_str();
}

size_t ziro_chat_session_stop_count(const ziro_chat_session * session) {
    return session == nullptr ? 0 : session->stops.size();
}

const char * ziro_chat_session_stop(const ziro_chat_session * session, size_t index) {
    if (session == nullptr || index >= session->stops.size()) { return ""; }
    return session->stops[index].c_str();
}

const char * ziro_chat_session_format(const ziro_chat_session * session) {
    if (session == nullptr) { return ""; }
    return common_chat_format_name(session->impl.format());
}

int ziro_chat_session_feed(ziro_chat_session * session, const char * text, size_t length) {
    if (session == nullptr) { return -1; }
    try {
        session->impl.feed(common_chat_input(std::string(text == nullptr ? "" : text, length)));
        return 0;
    } catch (...) {
        return 1;
    }
}

int ziro_chat_session_finish(ziro_chat_session * session, const char * text, size_t length) {
    if (session == nullptr) { return -1; }
    try {
        session->impl.finish(common_chat_input(std::string(text == nullptr ? "" : text, length)));
        return 0;
    } catch (...) {
        return 1;
    }
}

const char * ziro_chat_session_content(const ziro_chat_session * session) {
    if (session == nullptr) { return ""; }
    return session->impl.msg().content.c_str();
}

const char * ziro_chat_session_reasoning(const ziro_chat_session * session) {
    if (session == nullptr) { return ""; }
    return session->impl.msg().reasoning_content.c_str();
}
