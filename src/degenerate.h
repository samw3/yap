#pragma once
#include <cstring>
#include <string>

namespace yap {

// Does `s` end with some window repeated back-to-back at least 3 times?
// This is what an actual generation loop looks like ("...and so on and so on and
// so on"). Checking for a repeated TAIL specifically avoids false-positiving on
// ordinary text that happens to repeat a phrase somewhere in the middle.
inline bool has_tail_loop(const std::string & s) {
    for (size_t w = 4; w <= 40; ++w) {
        if (s.size() < w * 3) break;
        const char * end = s.data() + s.size();
        if (std::memcmp(end - w, end - w * 2, w) == 0 &&
            std::memcmp(end - w, end - w * 3, w) == 0) {
            return true;
        }
    }
    return false;
}

// Should we reject the normalizer's output and fall back to the raw transcript?
//
// Erring toward acceptance on purpose: a false positive means the user silently
// gets un-normalized text (fillers left in), which is mildly worse output. A
// false negative means we inject a repetition loop. Both are bad, but the checks
// below are all things a correct normalizer would never do.
inline bool looks_degenerate(const std::string & out, const std::string & in) {
    if (out.empty()) return true;

    // Runaway generation. A normalizer removes filler; it never triples length.
    if (out.size() > in.size() * 3 + 64) return true;

    // Lost most of the content. Legitimate filler removal is nowhere near this
    // aggressive. Only applied to inputs long enough for the ratio to mean
    // something.
    if (in.size() > 40 && out.size() * 4 < in.size()) return true;

    if (has_tail_loop(out)) return true;

    return false;
}

}  // namespace yap
