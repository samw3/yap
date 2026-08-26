#pragma once
#include "asr.h"
#include "normalizer.h"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace yap {

struct Result {
    std::string transcript;    // raw from Parakeet
    std::string text;          // normalized (or transcript, if normalization was rejected)
    bool   ok            = false;
    bool   normalized    = false;
    double asr_ms        = 0;
    double prefill_ms    = 0;
    double gen_ms        = 0;
    double total_ms      = 0;
};

// Owns both models on ONE dedicated worker thread.
//
// A single llama_context is not thread-safe, and llama_decode allocates, takes
// locks, and blocks on the GPU -- so it must never be touched from the audio
// thread. The worker also runs at USER_INITIATED QoS: macOS confines UTILITY and
// BACKGROUND work to the efficiency cores, which would cost several x on this
// workload, and ggml never sets a QoS class of its own so its threadpool inherits
// whatever the calling thread has.
class Pipeline {
public:
    using Done   = std::function<void(Result)>;
    using Staged = std::function<void(const char * stage)>;

    ~Pipeline();

    // Starts the worker; models load and warm up asynchronously so app launch is
    // not blocked. `on_ready` fires on the worker when both are usable.
    void start(const std::string & asr_model, const std::string & llm_model,
               std::function<void(bool)> on_ready);
    void stop();

    // 16 kHz mono float. Queued if the worker is busy; never interleaved.
    void submit(std::vector<float> pcm16k, Style style, Staged on_stage, Done on_done);

    bool ready() const { return ready_.load(std::memory_order_acquire); }
    size_t pending() const;

private:
    void run(std::string asr_model, std::string llm_model, std::function<void(bool)> on_ready);

    struct Job {
        std::vector<float> pcm;
        Style              style;
        Staged             on_stage;
        Done               on_done;
    };

    Asr        asr_;
    Normalizer norm_;

    std::thread             thread_;
    mutable std::mutex      mu_;
    std::condition_variable cv_;
    std::deque<Job>         jobs_;
    bool                    quit_ = false;
    std::atomic<bool>       ready_{false};
};

}  // namespace yap
