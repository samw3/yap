#pragma once
#include <string>
#include <vector>

// Global scope on purpose: inside namespace yap these would become distinct types.
struct parakeet_context;
struct parakeet_state;

namespace yap {

// Parakeet TDT via whisper.cpp's `parakeet` target (independent of `whisper`).
// Not thread-safe: own one instance on one worker thread.
class Asr {
public:
    ~Asr();
    bool load(const std::string & model_path, int n_threads = 6);

    // Runs a dummy inference so Metal compiles its pipelines at launch instead of
    // on the user's first keypress.
    void warm_up();

    // `pcm` must be 16 kHz mono float. Returns transcript, or empty on failure.
    std::string transcribe(const std::vector<float> & pcm);

    bool loaded() const { return ctx_ != nullptr; }
    double last_ms() const { return last_ms_; }

private:
    ::parakeet_context * ctx_   = nullptr;
    ::parakeet_state *   state_ = nullptr;
    int    n_threads_ = 6;
    double last_ms_   = 0;
};

}  // namespace yap
