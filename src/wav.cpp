#include "wav.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>

namespace yap {

static void put32(FILE * f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void put16(FILE * f, uint16_t v) { fwrite(&v, 2, 1, f); }

bool write_wav_16k_mono(const std::string & path, const std::vector<float> & samples) {
    FILE * f = fopen(path.c_str(), "wb");
    if (!f) return false;

    const uint32_t rate = 16000, channels = 1, bits = 16;
    const uint32_t data_bytes = (uint32_t) (samples.size() * sizeof(int16_t));

    fwrite("RIFF", 1, 4, f);  put32(f, 36 + data_bytes);
    fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f);  put32(f, 16);
    put16(f, 1);                                  // PCM
    put16(f, (uint16_t) channels);
    put32(f, rate);
    put32(f, rate * channels * bits / 8);         // byte rate
    put16(f, (uint16_t) (channels * bits / 8));   // block align
    put16(f, (uint16_t) bits);
    fwrite("data", 1, 4, f);  put32(f, data_bytes);

    for (float s : samples) {
        // Clamp before scaling: a float slightly outside [-1,1] would otherwise
        // wrap to the opposite polarity and sound like a click.
        const float c = std::max(-1.0f, std::min(1.0f, s));
        const int16_t v = (int16_t) std::lround(c * 32767.0f);
        fwrite(&v, sizeof(v), 1, f);
    }
    const bool ok = ferror(f) == 0;
    fclose(f);
    return ok;
}

}  // namespace yap
