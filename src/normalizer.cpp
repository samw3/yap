#include "normalizer.h"
#include "log.h"
#include "utf8.h"
#include "llama.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

namespace yap {

// Fixed by the s1-mini model card; must be byte-exact.
static const char * kSystemPrompt =
    "You are a text normalizer for speech-to-text transcripts. The input begins with a control "
    "line specifying the styling, structure, and context settings; clean the transcript to match "
    "those settings and output only the cleaned text.";

static double ms_since(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
}

std::string Style::control_line() const {
    const char * st = "semi-formal";
    switch (styling) {
        case Styling::Casual:     st = "casual";      break;
        case Styling::SemiCasual: st = "semi-casual"; break;
        case Styling::SemiFormal: st = "semi-formal"; break;
        case Styling::Formal:     st = "formal";      break;
    }
    const char * sr = structure == Structure::Lists ? "lists" : "prose";
    const char * cx = context   == Context::Email   ? "email" : "general";
    return std::string("[Styling: ") + st + "] [Structure: " + sr + "] [Context: " + cx + "]";
}

Normalizer::~Normalizer() {
    if (smpl_)  llama_sampler_free(smpl_);
    if (ctx_)   llama_free(ctx_);
    if (model_) llama_model_free(model_);
}

bool Normalizer::load(const std::string & gguf_path) {
    auto mp = llama_model_default_params();   // n_gpu_layers already defaults to -1 (all)

    const auto t0 = std::chrono::steady_clock::now();
    model_ = llama_model_load_from_file(gguf_path.c_str(), mp);
    if (!model_) {
        YAP_WARN("s1-mini load failed: %{public}s", gguf_path.c_str());
        return false;
    }
    vocab_ = llama_model_get_vocab(model_);

    auto cp = llama_context_default_params();
    cp.n_ctx           = 1536;   // padded internally to a multiple of 256
    cp.n_batch         = 1024;
    cp.n_ubatch        = 512;
    cp.n_seq_max       = 1;
    cp.kv_unified      = true;
    cp.n_threads       = 4;      // Metal does the work; do NOT use all 10 cores --
    cp.n_threads_batch = 8;      // ggml's barrier runs at the slowest thread's speed
                                 // and an efficiency core stalls the whole thing.
    ctx_ = llama_init_from_model(model_, cp);
    if (!ctx_) {
        YAP_WARN("llama context creation failed");
        llama_model_free(model_); model_ = nullptr;
        return false;
    }

    smpl_ = llama_sampler_chain_init(llama_sampler_chain_default_params());
    // Pure greedy: the model was trained deterministically. Not temp(0.0)
    // (division by zero) and no trailing dist sampler.
    llama_sampler_chain_add(smpl_, llama_sampler_init_greedy());

    // Partial KV truncation is what makes prefix caching possible; verify rather
    // than assume. Qwen3 dense is full attention, so this should be 0.
    const int32_t n_swa = llama_model_n_swa(model_);
    if (n_swa != 0) YAP_WARN("model reports n_swa=%d — prefix KV reuse may be unsupported", n_swa);

    YAP_LOG("s1-mini loaded in %.0f ms (n_swa=%d add_bos=%d)",
            ms_since(t0), n_swa, (int) llama_vocab_get_add_bos(vocab_));
    return true;
}

std::vector<int32_t> Normalizer::tokenize(const std::string & s, bool parse_special) const {
    // add_special=false: Qwen3 has add_bos_token=false.
    // parse_special=true is MANDATORY, or <|im_start|> / <think> are shredded
    // into ordinary text tokens and the model's behavior collapses.
    int n = -llama_tokenize(vocab_, s.data(), (int32_t) s.size(), nullptr, 0, false, parse_special);
    std::vector<int32_t> out(n > 0 ? n : 0);
    if (n > 0) llama_tokenize(vocab_, s.data(), (int32_t) s.size(),
                              out.data(), (int32_t) out.size(), false, parse_special);
    return out;
}

std::string Normalizer::build_prompt(const std::string & transcript, const Style & style) const {
    // Hand-built ChatML. enable_thinking=false is NOT expressible through
    // llama.cpp's public C API (llama_chat_apply_template does not parse Jinja and
    // has no kwargs), and the empty <think> block below is exactly what Qwen3's
    // template emits for it. Omit it and the model returns blank output.
    return std::string("<|im_start|>system\n") + kSystemPrompt +
           "<|im_end|>\n<|im_start|>user\n" + style.control_line() + "\n" + transcript +
           "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
}

void Normalizer::warm_up() {
    if (!ctx_) return;
    const auto t0 = std::chrono::steady_clock::now();

    // Prefill (multi-token batch) and generation (batch of 1) are different Metal
    // graph shapes and compile different pipeline sets. Warm both.
    int32_t wt = llama_vocab_bos(vocab_);
    if (wt == LLAMA_TOKEN_NULL) wt = 0;
    std::vector<int32_t> warm(128, wt);
    llama_decode(ctx_, llama_batch_get_one(warm.data(), (int32_t) warm.size()));
    llama_decode(ctx_, llama_batch_get_one(&wt, 1));
    (void) llama_sampler_sample(smpl_, ctx_, -1);
    llama_sampler_reset(smpl_);
    llama_memory_clear(llama_get_memory(ctx_), true);
    llama_synchronize(ctx_);

    // Now prefill the real static prefix and leave it cached for every request.
    const std::string prefix = std::string("<|im_start|>system\n") + kSystemPrompt +
                               "<|im_end|>\n<|im_start|>user\n";
    prefix_toks_ = tokenize(prefix, true);
    if (!prefix_toks_.empty()) {
        llama_decode(ctx_, llama_batch_get_one(prefix_toks_.data(), (int32_t) prefix_toks_.size()));
        llama_synchronize(ctx_);
    }
    YAP_LOG("s1-mini warm-up %.0f ms, prefix cached (%zu tokens)",
            ms_since(t0), prefix_toks_.size());
}

bool Normalizer::looks_degenerate(const std::string & out, const std::string & in) {
    if (out.empty()) return true;
    // Runaway generation: a normalizer should never balloon the text.
    if (out.size() > in.size() * 3 + 64) return true;
    // Immediate repetition loop: same 24-char window three times running.
    if (out.size() > 96) {
        const std::string w = out.substr(out.size() - 24);
        size_t hits = 0, pos = 0;
        while ((pos = out.find(w, pos)) != std::string::npos) { ++hits; pos += 1; }
        if (hits >= 3) return true;
    }
    return false;
}

std::string Normalizer::generate(int max_new) {
    std::string out;
    std::string pending;   // holds incomplete UTF-8 sequences across tokens

    for (int i = 0; i < max_new; ++i) {
        int32_t id = llama_sampler_sample(smpl_, ctx_, -1);
        if (llama_vocab_is_eog(vocab_, id)) break;

        char buf[256];
        // special=false so stray control tokens never render as literal text.
        const int nb = llama_token_to_piece(vocab_, id, buf, sizeof(buf), 0, false);
        if (nb > 0) {
            pending.append(buf, nb);
            const size_t good = complete_utf8_prefix(pending);
            out.append(pending, 0, good);
            pending.erase(0, good);
        }
        ++last_tokens_;
        if (llama_decode(ctx_, llama_batch_get_one(&id, 1)) != 0) break;
    }
    out += pending;   // flush whatever remains

    // Belt and braces: some fine-tunes have odd EOG metadata.
    const size_t im = out.find("<|im_end|>");
    if (im != std::string::npos) out.resize(im);
    return out;
}

std::string Normalizer::normalize(const std::string & transcript, const Style & style) {
    if (!ctx_ || transcript.empty()) return transcript;

    last_tokens_ = 0;
    const std::string prompt = build_prompt(transcript, style);
    const std::vector<int32_t> toks = tokenize(prompt, true);

    if ((int) toks.size() >= llama_n_ctx_seq(ctx_) - 64) {
        YAP_WARN("prompt %zu tokens exceeds context — returning transcript unchanged",
                 toks.size());
        return transcript;
    }

    llama_memory_t mem = llama_get_memory(ctx_);

    // Reuse the cached static prefix when the tokenization genuinely matches.
    // Longest-common-prefix rather than a fixed split: BPE is not compositional,
    // so a naive split can silently desync the cached KV from the real prompt.
    size_t keep = 0;
    while (keep < prefix_toks_.size() && keep < toks.size() && prefix_toks_[keep] == toks[keep]) ++keep;
    if (keep > 0 && !llama_memory_seq_rm(mem, 0, (int32_t) keep, -1)) {
        YAP_INFO("partial KV removal unsupported — clearing and reprefilling");
        llama_memory_clear(mem, true);
        keep = 0;
    } else if (keep == 0) {
        llama_memory_clear(mem, true);
    }
    llama_sampler_reset(smpl_);

    const auto t0 = std::chrono::steady_clock::now();
    if (keep < toks.size()) {
        std::vector<int32_t> tail(toks.begin() + keep, toks.end());
        if (llama_decode(ctx_, llama_batch_get_one(tail.data(), (int32_t) tail.size())) != 0) {
            YAP_WARN("prefill failed — returning transcript unchanged");
            return transcript;
        }
    }
    // llama_decode only ENQUEUES Metal work; without this the timing is a lie and
    // the cost silently reappears in the generation measurement.
    llama_synchronize(ctx_);
    last_prefill_ms_ = ms_since(t0);

    const int max_new = (int) (1.3 * toks.size()) + 32;
    const auto t1 = std::chrono::steady_clock::now();
    std::string out = generate(max_new);
    last_gen_ms_ = ms_since(t1);

    // Trim surrounding whitespace the model sometimes emits.
    const size_t b = out.find_first_not_of(" \t\n\r");
    const size_t e = out.find_last_not_of(" \t\n\r");
    out = (b == std::string::npos) ? std::string() : out.substr(b, e - b + 1);

    if (looks_degenerate(out, transcript)) {
        YAP_WARN("s1-mini output looked degenerate (%zu chars from %zu) — using raw transcript",
                 out.size(), transcript.size());
        return transcript;
    }

    YAP_INFO("normalize: prefill %.1f ms (reused %zu/%zu tok), gen %.1f ms (%d tok)",
             last_prefill_ms_, keep, toks.size(), last_gen_ms_, last_tokens_);
    return out;
}

}  // namespace yap
