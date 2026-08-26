#pragma once
#include <string>
#include <vector>

// Forward declarations MUST be at global scope: declaring them inside namespace
// yap would create yap::llama_model, a different type from ::llama_model, and
// every call would fail to match.
struct llama_model;
struct llama_context;
struct llama_vocab;
struct llama_sampler;

namespace yap {

// Control line is part of the input format s1-mini was trained on -- not a
// suggestion. Both the system prompt and this line must always be sent.
struct Style {
    enum class Styling   { Casual, SemiCasual, SemiFormal, Formal };
    enum class Structure { Prose, Lists };
    enum class Context   { General, Email };
    Styling   styling   = Styling::SemiFormal;
    Structure structure = Structure::Prose;
    Context   context   = Context::General;
    std::string control_line() const;
};

// S1-mini by Superwhisper: turns a raw transcript into clean written text.
// Not thread-safe: own one instance on one worker thread.
class Normalizer {
public:
    ~Normalizer();
    bool load(const std::string & gguf_path);
    void warm_up();

    // Returns cleaned text. On ANY failure or degenerate output, returns the
    // input unchanged -- never lose the user's words to a misbehaving model.
    std::string normalize(const std::string & transcript, const Style & style);

    bool loaded() const { return ctx_ != nullptr; }
    double last_prefill_ms() const { return last_prefill_ms_; }
    double last_gen_ms()     const { return last_gen_ms_; }
    int    last_tokens()     const { return last_tokens_; }

    // Exposed for tests: the exact prompt we send.
    std::string build_prompt(const std::string & transcript, const Style & style) const;

private:
    std::vector<int32_t> tokenize(const std::string & s, bool parse_special) const;
    std::string generate(int max_new);
    static bool looks_degenerate(const std::string & out, const std::string & in);

    ::llama_model *   model_ = nullptr;
    ::llama_context * ctx_   = nullptr;
    const ::llama_vocab * vocab_ = nullptr;
    ::llama_sampler * smpl_  = nullptr;

    std::vector<int32_t> prefix_toks_;   // KV-cached static prefix
    double last_prefill_ms_ = 0, last_gen_ms_ = 0;
    int    last_tokens_ = 0;
};

}  // namespace yap
