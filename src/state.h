#pragma once
#include <cstdint>

namespace yap {

// One enum for everything the menu-bar icon can be showing. The last few are the
// entire user-visible support surface -- if the app is broken, it is one of these.
enum class State : uint8_t {
    NeedsPermissions,  // missing Microphone and/or Accessibility
    Idle,              // engine torn down after idle timeout
    Arming,            // engine spinning up (~100-300 ms)
    Armed,             // engine hot, pre-roll available, waiting on F11
    Recording,         // F11 held
    Transcribing,      // parakeet running
    Normalizing,       // s1-mini running
    Injecting,         // writing pasteboard / posting Cmd+V
    SecureInput,       // a password field has focus; we cannot see keys or inject
    TapDead,           // event tap died and could not be revived
};

const char * state_name(State s);
const char * state_detail(State s);   // one line for the menu

}  // namespace yap
