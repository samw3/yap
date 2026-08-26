// Phase 0 smoke test: prove libllama (s1-mini) and libparakeet coexist in ONE
// process on ONE shared ggml, and that the hand-built ChatML prompt works.
#include "llama.h"
#include "parakeet.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using clk = std::chrono::steady_clock;
static double ms_since(clk::time_point t) {
    return std::chrono::duration<double, std::milli>(clk::now() - t).count();
}

// --- minimal 16-bit PCM mono WAV reader (our capture path produces exactly this) ---
static bool load_wav_16k_mono(const char * path, std::vector<float> & out) {
    FILE * f = fopen(path, "rb");
    if (!f) return false;
    unsigned char hdr[44];
    if (fread(hdr, 1, 44, f) != 44) { fclose(f); return false; }
    if (memcmp(hdr, "RIFF", 4) || memcmp(hdr + 8, "WAVE", 4)) { fclose(f); return false; }
    const int channels    = hdr[22] | (hdr[23] << 8);
    const int sample_rate = hdr[24] | (hdr[25] << 8) | (hdr[26] << 16) | (hdr[27] << 24);
    const int bits        = hdr[34] | (hdr[35] << 8);
    if (channels != 1 || sample_rate != PARAKEET_SAMPLE_RATE || bits != 16) {
        fprintf(stderr, "wav: expected 16k mono s16, got %dch %dHz %dbit\n", channels, sample_rate, bits);
        fclose(f); return false;
    }
    std::vector<int16_t> pcm;
    int16_t buf[4096];
    size_t n;
    while ((n = fread(buf, sizeof(int16_t), 4096, f)) > 0) pcm.insert(pcm.end(), buf, buf + n);
    fclose(f);
    out.resize(pcm.size());
    for (size_t i = 0; i < pcm.size(); ++i) out[i] = pcm[i] / 32768.0f;
    return true;
}

static std::vector<llama_token> tok(const llama_vocab * v, const std::string & s,
                                    bool add_special, bool parse_special) {
    int n = -llama_tokenize(v, s.data(), (int32_t) s.size(), nullptr, 0, add_special, parse_special);
    std::vector<llama_token> out(n);
    llama_tokenize(v, s.data(), (int32_t) s.size(), out.data(), (int32_t) out.size(),
                   add_special, parse_special);
    return out;
}

// Fixed by the s1-mini model card. Must be byte-exact.
static const char * SYSTEM_PROMPT =
    "You are a text normalizer for speech-to-text transcripts. The input begins with a control "
    "line specifying the styling, structure, and context settings; clean the transcript to match "
    "those settings and output only the cleaned text.";

int main(int argc, char ** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <s1-mini.gguf> <parakeet.bin> <audio-16k-mono.wav>\n", argv[0]);
        return 1;
    }
    const char * llm_path = argv[1];
    const char * asr_path = argv[2];
    const char * wav_path = argv[3];

    llama_backend_init();
    llama_log_set([](enum ggml_log_level lvl, const char * txt, void *) {
        if (lvl >= GGML_LOG_LEVEL_WARN) fputs(txt, stderr);
    }, nullptr);

    // ================= ASR =================
    printf("\n=== parakeet ===\n");
    auto pcp = parakeet_context_default_params();
    pcp.use_gpu = true;
    auto t = clk::now();
    parakeet_context * pctx = parakeet_init_from_file_with_params(asr_path, pcp);
    if (!pctx) { fprintf(stderr, "parakeet load failed\n"); return 2; }
    printf("load            : %.0f ms\n", ms_since(t));

    std::vector<float> pcm;
    if (!load_wav_16k_mono(wav_path, pcm)) { fprintf(stderr, "wav load failed\n"); return 2; }
    printf("audio           : %.2f s\n", pcm.size() / (double) PARAKEET_SAMPLE_RATE);

    auto ppp = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
    ppp.n_threads  = 6;
    ppp.no_context = true;

    t = clk::now();
    parakeet_full(pctx, ppp, pcm.data(), (int) pcm.size());   // warm-up
    printf("warm-up infer   : %.1f ms\n", ms_since(t));

    t = clk::now();
    if (parakeet_full(pctx, ppp, pcm.data(), (int) pcm.size()) != 0) {
        fprintf(stderr, "parakeet_full failed\n"); return 2;
    }
    const double asr_ms = ms_since(t);
    std::string transcript;
    for (int i = 0; i < parakeet_full_n_segments(pctx); ++i)
        transcript += parakeet_full_get_segment_text(pctx, i);
    printf("steady infer    : %.1f ms\n", asr_ms);
    printf("transcript      : %s\n", transcript.c_str());

    // ================= LLM =================
    printf("\n=== s1-mini ===\n");
    auto mp = llama_model_default_params();
    t = clk::now();
    llama_model * model = llama_model_load_from_file(llm_path, mp);
    if (!model) { fprintf(stderr, "llama load failed\n"); return 3; }
    printf("load            : %.0f ms\n", ms_since(t));

    const llama_vocab * vocab = llama_model_get_vocab(model);
    printf("n_swa           : %d (0 == full attention, partial KV truncation OK)\n",
           llama_model_n_swa(model));
    printf("add_bos         : %s\n", llama_vocab_get_add_bos(vocab) ? "true" : "false");

    auto cp = llama_context_default_params();
    cp.n_ctx = 1536; cp.n_batch = 1024; cp.n_ubatch = 512;
    cp.n_seq_max = 1; cp.n_threads = 4; cp.n_threads_batch = 8;
    llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) { fprintf(stderr, "llama ctx failed\n"); return 3; }

    llama_sampler * smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());   // pure greedy, temp 0

    // ---- warm-up: prefill and generation are DIFFERENT Metal graph shapes and so
    // compile different pipeline sets. Warm both, or the user's first keypress pays for it.
    if (getenv("YAP_NO_WARMUP") == nullptr) {
        t = clk::now();
        llama_token wt = llama_vocab_bos(vocab) != LLAMA_TOKEN_NULL ? llama_vocab_bos(vocab) : 0;
        std::vector<llama_token> warm(128, wt);
        llama_decode(ctx, llama_batch_get_one(warm.data(), (int32_t) warm.size())); // prefill shape
        llama_decode(ctx, llama_batch_get_one(&wt, 1));                             // generation shape
        (void) llama_sampler_sample(smpl, ctx, -1);                                 // sampler path
        llama_sampler_reset(smpl);
        llama_memory_clear(llama_get_memory(ctx), true);
        llama_synchronize(ctx);
        printf("warm-up         : %.1f ms (both graph shapes)\n", ms_since(t));
    }

    // Hand-built ChatML with thinking disabled -- the empty <think> block is what
    // enable_thinking=false emits. Getting this wrong yields blank output.
    const std::string prefix = std::string("<|im_start|>system\n") + SYSTEM_PROMPT +
                               "<|im_end|>\n<|im_start|>user";
    const std::string tail = std::string("\n[Styling: semi-formal] [Structure: prose] [Context: general]\n") +
                             transcript + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";

    // Verify the prefix/tail split is tokenization-safe before relying on prefix KV caching.
    {
        auto a = tok(vocab, prefix, false, true);
        auto b = tok(vocab, tail, false, true);
        auto whole = tok(vocab, prefix + tail, false, true);
        std::vector<llama_token> cat = a; cat.insert(cat.end(), b.begin(), b.end());
        printf("split-safe      : %s (prefix=%zu tail=%zu whole=%zu)\n",
               cat == whole ? "YES" : "NO -- use LCP diffing", a.size(), b.size(), whole.size());
    }

    auto prompt_toks = tok(vocab, prefix + tail, false, true);
    printf("prompt tokens   : %zu\n", prompt_toks.size());

    t = clk::now();
    if (llama_decode(ctx, llama_batch_get_one(prompt_toks.data(), (int32_t) prompt_toks.size()))) {
        fprintf(stderr, "prefill failed\n"); return 3;
    }
    llama_synchronize(ctx);   // llama_decode only ENQUEUES Metal work; without this the
                              // timer measures the enqueue and the real cost hides in ttft.
    const double prefill_ms = ms_since(t);

    std::string out;
    const int max_new = (int) (1.3 * prompt_toks.size()) + 32;
    int n_gen = 0;
    double ttft_ms = -1;
    t = clk::now();
    for (; n_gen < max_new; ++n_gen) {
        llama_token id = llama_sampler_sample(smpl, ctx, -1);
        if (ttft_ms < 0) ttft_ms = ms_since(t);
        if (llama_vocab_is_eog(vocab, id)) break;
        char buf[256];
        int nb = llama_token_to_piece(vocab, id, buf, sizeof(buf), 0, false);
        if (nb > 0) out.append(buf, nb);
        if (llama_decode(ctx, llama_batch_get_one(&id, 1))) break;
    }
    const double gen_ms = ms_since(t);

    printf("prefill         : %.1f ms (%zu tok -> %.0f tok/s)\n",
           prefill_ms, prompt_toks.size(), prompt_toks.size() / (prefill_ms / 1000.0));
    printf("ttft            : %.1f ms\n", ttft_ms);
    printf("generate        : %.1f ms (%d tok -> %.1f tok/s, %.2f ms/tok)\n",
           gen_ms, n_gen, n_gen / (gen_ms / 1000.0), gen_ms / (n_gen ? n_gen : 1));
    printf("normalized      : %s\n", out.c_str());
    printf("\n=== end-to-end (post key-release) : %.1f ms ===\n", asr_ms + prefill_ms + gen_ms);

    llama_sampler_free(smpl);
    llama_free(ctx);
    llama_model_free(model);
    parakeet_free(pctx);
    llama_backend_free();
    return 0;
}
