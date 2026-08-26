#include "pipeline.h"
#include "log.h"

#include <chrono>
#include <pthread/qos.h>

namespace yap {

static double ms_since(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
}

Pipeline::~Pipeline() { stop(); }

void Pipeline::start(const std::string & asr_model, const std::string & llm_model,
                     std::function<void(bool)> on_ready) {
    thread_ = std::thread(&Pipeline::run, this, asr_model, llm_model, std::move(on_ready));
}

void Pipeline::stop() {
    {
        std::lock_guard<std::mutex> lk(mu_);
        quit_ = true;
    }
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
}

size_t Pipeline::pending() const {
    std::lock_guard<std::mutex> lk(mu_);
    return jobs_.size();
}

void Pipeline::submit(std::vector<float> pcm16k, Style style, Staged on_stage, Done on_done) {
    {
        std::lock_guard<std::mutex> lk(mu_);
        jobs_.push_back(Job{std::move(pcm16k), style, std::move(on_stage), std::move(on_done)});
    }
    cv_.notify_one();
}

void Pipeline::run(std::string asr_model, std::string llm_model,
                   std::function<void(bool)> on_ready) {
    // Do this FIRST: ggml's worker threads inherit the QoS of whichever thread
    // creates the session, and a low QoS pins the whole thing to efficiency cores.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);

    const bool asr_ok = asr_.load(asr_model, /*n_threads=*/6);
    const bool llm_ok = norm_.load(llm_model);

    if (asr_ok) asr_.warm_up();
    if (llm_ok) norm_.warm_up();

    const bool ok = asr_ok && llm_ok;
    ready_.store(ok, std::memory_order_release);
    if (on_ready) on_ready(ok);
    if (!ok) YAP_WARN("pipeline not ready (asr=%d llm=%d)", (int) asr_ok, (int) llm_ok);
    else     YAP_LOG("pipeline ready — models warm");

    for (;;) {
        Job job;
        {
            std::unique_lock<std::mutex> lk(mu_);
            cv_.wait(lk, [this] { return quit_ || !jobs_.empty(); });
            if (quit_ && jobs_.empty()) break;
            job = std::move(jobs_.front());
            jobs_.pop_front();
        }

        Result r;
        const auto t0 = std::chrono::steady_clock::now();

        if (job.on_stage) job.on_stage("transcribing");
        r.transcript = asr_.transcribe(job.pcm);
        r.asr_ms = asr_.last_ms();

        if (r.transcript.empty()) {
            r.total_ms = ms_since(t0);
            YAP_LOG("asr produced nothing (%.1f ms)", r.asr_ms);
            if (job.on_done) job.on_done(std::move(r));
            continue;
        }

        if (job.on_stage) job.on_stage("normalizing");
        r.text = norm_.normalize(r.transcript, job.style);
        r.prefill_ms = norm_.last_prefill_ms();
        r.gen_ms     = norm_.last_gen_ms();
        r.normalized = (r.text != r.transcript);
        r.ok = true;
        r.total_ms = ms_since(t0);

        YAP_LOG("pipeline %.0f ms total (asr %.0f, prefill %.0f, gen %.0f)%{public}s",
                r.total_ms, r.asr_ms, r.prefill_ms, r.gen_ms,
                r.normalized ? "" : " [normalizer made no change]");

        if (job.on_done) job.on_done(std::move(r));
    }
}

}  // namespace yap
