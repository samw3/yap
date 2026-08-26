#include "asr.h"
#include "log.h"
#include "parakeet.h"

#include <chrono>

namespace yap {

static double ms_since(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
}

Asr::~Asr() {
    if (state_) parakeet_free_state(state_);
    if (ctx_)   parakeet_free(ctx_);
}

bool Asr::load(const std::string & model_path, int n_threads) {
    n_threads_ = n_threads;
    auto cp = parakeet_context_default_params();
    cp.use_gpu = true;

    const auto t0 = std::chrono::steady_clock::now();
    ctx_ = parakeet_init_from_file_with_params(model_path.c_str(), cp);
    if (!ctx_) {
        YAP_WARN("parakeet load failed: %{public}s", model_path.c_str());
        return false;
    }
    // One state, allocated once and reused. Transcription must go through
    // parakeet_full_with_state(), never parakeet_chunk(): chunk() is the streaming
    // entry point and only appends to state->result_all, so reusing a state across
    // utterances concatenates them. Only *_full_with_state() clears it.
    //
    // It also takes the dynamic-encoder path for audio longer than n_audio_ctx,
    // where chunk() truncates to it -- and n_audio_ctx is 5000 mel frames, which
    // at a 160-sample hop is 50 s, well inside the 120 s hold we allow.
    state_ = parakeet_init_state(ctx_);
    if (!state_) {
        YAP_WARN("parakeet_init_state failed");
        parakeet_free(ctx_);
        ctx_ = nullptr;
        return false;
    }
    YAP_LOG("parakeet loaded in %.0f ms (%d threads)", ms_since(t0), n_threads_);
    return true;
}

void Asr::warm_up() {
    if (!ctx_) return;
    const auto t0 = std::chrono::steady_clock::now();
    std::vector<float> silence(16000, 0.0f);   // 1 s
    auto pp = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
    pp.n_threads  = n_threads_;
    pp.no_context = true;
    parakeet_full_with_state(ctx_, state_, pp, silence.data(), (int) silence.size());
    YAP_LOG("parakeet warm-up %.0f ms", ms_since(t0));
}

std::string Asr::transcribe(const std::vector<float> & pcm) {
    if (!ctx_ || pcm.empty()) return {};

    auto pp = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
    pp.n_threads  = n_threads_;
    // Each dictation is independent; without this, one utterance conditions the
    // next and errors compound across presses.
    pp.no_context = true;

    const auto t0 = std::chrono::steady_clock::now();
    if (parakeet_full_with_state(ctx_, state_, pp, pcm.data(), (int) pcm.size()) != 0) {
        YAP_WARN("parakeet transcription failed");
        return {};
    }
    last_ms_ = ms_since(t0);

    std::string out;
    const int n = parakeet_full_n_segments_from_state(state_);
    for (int i = 0; i < n; ++i) {
        const char * seg = parakeet_full_get_segment_text_from_state(state_, i);
        if (seg) out += seg;
    }

    // Trim: leading/trailing whitespace is common and would otherwise be baked
    // into the s1-mini prompt.
    const size_t b = out.find_first_not_of(" \t\n\r");
    const size_t e = out.find_last_not_of(" \t\n\r");
    if (b == std::string::npos) return {};
    return out.substr(b, e - b + 1);
}

}  // namespace yap
