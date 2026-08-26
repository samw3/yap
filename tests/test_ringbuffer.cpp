#include "ringbuffer.h"
#include <atomic>
#include <cstdio>
#include <thread>
#include <vector>

using yap::RingBuffer;
using yap::ReadResult;

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

int main() {
    { RingBuffer r(1000); CHECK(r.capacity() == 1024); }
    { RingBuffer r(1024); CHECK(r.capacity() == 1024); }

    // round-trip
    {
        RingBuffer r(16);
        float in[4] = {1, 2, 3, 4};
        r.write(in, 4);
        CHECK(r.written() == 4);
        std::vector<float> out;
        ReadResult res = r.read_range(0, 4, out);
        CHECK(res.valid && res.count == 4 && res.first_frame == 0 && !res.skipped);
        for (int i = 0; i < 4; ++i) CHECK(out[i] == in[i]);
    }

    // wrap-around, with eviction reported via `skipped`
    {
        RingBuffer r(8);
        float a[6] = {1, 2, 3, 4, 5, 6};   r.write(a, 6);
        float b[5] = {7, 8, 9, 10, 11};    r.write(b, 5);
        CHECK(r.written() == 11);
        CHECK(r.oldest_available() == 3);
        std::vector<float> out;
        ReadResult res = r.read_range(0, 11, out);
        CHECK(res.valid);
        CHECK(res.skipped);                       // frames 0..2 were gone
        CHECK(res.first_frame == 3);
        CHECK(res.count == 8);
        for (int i = 0; i < 8; ++i) CHECK(out[i] == float(i + 4));
    }

    // pre-roll: read starting before "now"
    {
        RingBuffer r(1024);
        std::vector<float> in(600);
        for (size_t i = 0; i < in.size(); ++i) in[i] = float(i);
        r.write(in.data(), in.size());
        const uint64_t now = r.written();
        std::vector<float> out;
        ReadResult res = r.read_range(now - 100, now, out);
        CHECK(res.valid && res.count == 100 && !res.skipped);
        CHECK(out.front() == 500.0f);
        CHECK(out.back()  == 599.0f);
    }

    // degenerate inputs
    {
        RingBuffer r(16);
        std::vector<float> out;
        CHECK(r.read_range(0, 0, out).count == 0);
        CHECK(out.empty());
        CHECK(r.read_range(5, 3, out).count == 0);
        CHECK(out.empty());
        float one = 42; r.write(&one, 1);
        r.write(nullptr, 4);                       // null src must be a no-op
        r.write(&one, 0);
        CHECK(r.written() == 1);
    }

    // chunk larger than capacity keeps the tail
    {
        RingBuffer r(8);
        std::vector<float> big(20);
        for (size_t i = 0; i < big.size(); ++i) big[i] = float(i);
        r.write(big.data(), big.size());
        CHECK(r.written() == 20);              // counter tracks TRUE frames produced
        CHECK(r.oldest_available() == 12);     // ...so the loss is visible
        std::vector<float> out;
        ReadResult res = r.read_range(0, 20, out);
        CHECK(res.skipped && res.first_frame == 12 && res.count == 8);
        CHECK(out.size() == 8);
        CHECK(out.front() == 12.0f && out.back() == 19.0f);
    }

    // reset
    {
        RingBuffer r(16);
        float v[4] = {1,2,3,4}; r.write(v, 4);
        r.reset();
        CHECK(r.written() == 0);
        CHECK(r.oldest_available() == 0);
    }

    // --- concurrency: a consumer that KEEPS UP must never see a gap ---
    // This mirrors real use: the ring holds ~2 s and the worker drains every few ms.
    {
        RingBuffer r(1 << 16);              // 65536 frames of slack
        std::atomic<bool> stop{false};
        std::thread producer([&] {
            float v = 0;
            while (!stop.load(std::memory_order_relaxed)) {
                float chunk[64];
                for (float & f : chunk) f = v++;
                r.write(chunk, 64);
                std::this_thread::sleep_for(std::chrono::microseconds(50));
            }
        });
        uint64_t cursor = 0;
        int reads = 0, invalid = 0, skipped = 0;
        while (reads < 3000) {
            const uint64_t w = r.written();
            if (w > cursor) {
                std::vector<float> out;
                ReadResult res = r.read_range(cursor, w, out);
                if (!res.valid) { ++invalid; continue; }
                if (res.skipped) ++skipped;
                for (size_t i = 1; i < out.size(); ++i) {
                    if (out[i] != out[i - 1] + 1.0f) { printf("FAIL gap in kept-up read at %zu\n", i); ++failures; break; }
                }
                cursor = res.first_frame + res.count;
                ++reads;
            }
        }
        stop = true; producer.join();
        CHECK(invalid == 0);                 // a keeping-up consumer must never be lapped
        CHECK(skipped == 0);                 // ...and must never lose frames
        if (invalid || skipped) printf("  (invalid=%d skipped=%d)\n", invalid, skipped);
    }

    // --- data loss must be REPORTED, deterministically ---
    // `skipped` is the detector that matters in practice: it fires whenever the
    // requested start frame was already evicted. Prove it single-threaded so the
    // assertion is real rather than timing-dependent.
    {
        RingBuffer r(8);
        std::vector<float> v(24);
        for (size_t i = 0; i < v.size(); ++i) v[i] = float(i);
        r.write(v.data(), v.size());          // 24 frames through an 8-frame ring
        std::vector<float> out;
        ReadResult res = r.read_range(0, r.written(), out);   // ask for long-gone frames
        CHECK(res.skipped);                   // loss is announced, not hidden
        CHECK(res.valid);
        CHECK(res.first_frame == 16);
        CHECK(res.count == 8);
        CHECK(out.front() == 16.0f && out.back() == 23.0f);
    }

    // A lapping producer must never yield a torn buffer to a stale consumer.
    // NOTE: `valid == false` is a narrow mid-copy race that is not reliably
    // reproducible from a test, so this asserts the invariant (never return torn
    // data) and reports whether the seqlock path was actually exercised, rather
    // than pretending a green run proves it.
    {
        RingBuffer r(1024);
        std::atomic<bool> stop{false};
        std::thread producer([&] {
            float v = 0;
            while (!stop.load(std::memory_order_relaxed)) {
                float chunk[512];
                for (float & f : chunk) f = v++;
                r.write(chunk, 512);
            }
        });
        int torn = 0, invalid = 0, skips = 0;
        for (int i = 0; i < 20000; ++i) {
            std::vector<float> out;
            const uint64_t from = r.oldest_available();      // maximally stale start
            ReadResult res = r.read_range(from, r.written(), out);
            if (!res.valid) { ++invalid; CHECK(out.empty()); continue; }
            if (res.skipped) ++skips;
            for (size_t k = 1; k < out.size(); ++k) {
                if (out[k] != out[k - 1] + 1.0f) { ++torn; break; }
            }
        }
        stop = true; producer.join();
        CHECK(torn == 0);                     // the invariant that actually matters
        printf("  lapping producer: torn=%d  seqlock-rejections=%d  skips=%d%s\n",
               torn, invalid, skips,
               invalid == 0 ? "  (seqlock path not exercised this run)" : "");
    }

    printf(failures ? "%d FAILURES\n" : "all ring buffer tests passed\n", failures);
    return failures ? 1 : 0;
}
