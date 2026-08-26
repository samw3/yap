#pragma once
// Single-producer / single-consumer float ring buffer with pre-roll support.
//
// Producer is the AVAudioEngine tap block on a real-time thread: no allocation,
// no locks, no logging. write() is two memcpys and one release store.
//
// This is NOT a queue. To support pre-roll (audio from slightly before the key
// went down) the producer overwrites the oldest frames once full, and the consumer
// reads by absolute frame index -- which it may point into the past.
//
// CONTRACT: because the producer overwrites, a consumer that falls more than
// `capacity` frames behind loses data. That is unavoidable in an overwriting
// ring, so the only real requirement is that loss be *detectable* rather than
// silent -- silently corrupted audio would surface as garbled transcripts that
// look like model errors. read_range() therefore validates after copying
// (seqlock style) and reports `valid == false` instead of returning torn data.
//
// In practice the worker drains during recording, so the ring only needs a couple
// of seconds of slack and loss should never occur; `valid` is the alarm, not the
// expected path.
#include <atomic>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace yap {

struct ReadResult {
    uint64_t first_frame = 0;      // first absolute index actually copied
    size_t   count       = 0;      // frames appended to `out`
    bool     valid       = true;   // false => producer lapped us mid-copy; `out` unchanged
    bool     skipped     = false;  // true => `from` had already been evicted before we started
};

class RingBuffer {
public:
    // capacity_frames is rounded up to a power of two so wrapping is a mask.
    explicit RingBuffer(size_t capacity_frames) {
        size_t cap = 1;
        while (cap < capacity_frames) cap <<= 1;
        buf_.assign(cap, 0.0f);
        mask_ = cap - 1;
    }

    size_t capacity() const { return buf_.size(); }

    // ---- producer (real-time thread) ----
    void write(const float * src, size_t n) {
        if (n == 0 || src == nullptr) return;
        const uint64_t w = written_.load(std::memory_order_relaxed);

        // An oversized chunk can only keep its tail, but the frame counter still
        // advances by the TRUE count: absolute indices are a timeline, and
        // under-counting here would silently skew every pre-roll computation.
        size_t keep = n;
        if (keep > buf_.size()) {
            src += (n - buf_.size());
            keep = buf_.size();
        }
        const uint64_t tail_start = w + (n - keep);          // absolute index of kept data
        const size_t off = (size_t) (tail_start & mask_);
        const size_t first = std::min(keep, buf_.size() - off);
        std::memcpy(buf_.data() + off, src, first * sizeof(float));
        if (keep > first) std::memcpy(buf_.data(), src + first, (keep - first) * sizeof(float));
        written_.store(w + n, std::memory_order_release);
    }

    // ---- consumer (worker thread) ----
    uint64_t written() const { return written_.load(std::memory_order_acquire); }

    uint64_t oldest_available() const {
        const uint64_t w = written();
        return w > buf_.size() ? w - buf_.size() : 0;
    }

    // Append [from, to) to `out`. On valid == false nothing is appended.
    ReadResult read_range(uint64_t from, uint64_t to, std::vector<float> & out) const {
        ReadResult r;
        const uint64_t oldest = oldest_available();
        if (from < oldest) { from = oldest; r.skipped = true; }
        r.first_frame = from;
        if (to <= from) return r;

        const size_t n = (size_t) std::min<uint64_t>(to - from, buf_.size());
        const size_t start = out.size();
        out.resize(start + n);
        const size_t off = (size_t) (from & mask_);
        const size_t first = std::min(n, buf_.size() - off);
        std::memcpy(out.data() + start, buf_.data() + off, first * sizeof(float));
        if (n > first) std::memcpy(out.data() + start + first, buf_.data(), (n - first) * sizeof(float));

        // Validate: did the producer overwrite any of [from, from+n) while we copied?
        const uint64_t w_after = written_.load(std::memory_order_acquire);
        const uint64_t oldest_after = w_after > buf_.size() ? w_after - buf_.size() : 0;
        if (oldest_after > from) {
            out.resize(start);          // discard rather than hand back torn audio
            r.valid = false;
            r.count = 0;
            return r;
        }
        r.count = n;
        return r;
    }

    // Drops all history. Only safe with the producer stopped.
    void reset() {
        written_.store(0, std::memory_order_release);
        std::fill(buf_.begin(), buf_.end(), 0.0f);
    }

private:
    std::vector<float>    buf_;
    size_t                mask_ = 0;
    std::atomic<uint64_t> written_{0};   // monotonic absolute frame count
};

}  // namespace yap
