#pragma once
#include <cstddef>
#include <string>
#include <vector>

namespace yap {
// Write 16 kHz mono 16-bit PCM. Used for Phase 2 verification and for debugging
// captures; not on the hot path.
bool write_wav_16k_mono(const std::string & path, const std::vector<float> & samples);
}
