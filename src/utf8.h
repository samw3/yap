#pragma once
#include <cstddef>
#include <string>

namespace yap {

// Length of the longest prefix of `s` containing only COMPLETE UTF-8 sequences.
//
// A single LLM token can be a fragment of a multi-byte codepoint, so streaming
// token pieces straight through produces mojibake at the seams. Buffer the tail
// until it completes.
inline size_t complete_utf8_prefix(const std::string & s) {
    if (s.empty()) return 0;

    // Walk back over at most 3 continuation bytes to find the last lead byte.
    size_t i = s.size();
    int steps = 0;
    while (i > 0 && steps < 4) {
        const unsigned char c = (unsigned char) s[i - 1];
        if ((c & 0xC0) == 0x80) { --i; ++steps; continue; }   // continuation byte

        size_t need = 1;
        if ((c & 0x80) == 0x00)      need = 1;   // ASCII
        else if ((c & 0xE0) == 0xC0) need = 2;
        else if ((c & 0xF0) == 0xE0) need = 3;
        else if ((c & 0xF8) == 0xF0) need = 4;
        else                         need = 1;   // stray continuation/invalid: don't stall

        const size_t have = s.size() - (i - 1);
        return have >= need ? s.size() : i - 1;
    }
    // Nothing but continuation bytes (malformed): flush rather than stall forever.
    return s.size();
}

}  // namespace yap
