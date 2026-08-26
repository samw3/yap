#include "state.h"

namespace yap {

const char * state_name(State s) {
    switch (s) {
        case State::NeedsPermissions: return "NeedsPermissions";
        case State::Idle:             return "Idle";
        case State::Arming:           return "Arming";
        case State::Armed:            return "Armed";
        case State::Recording:        return "Recording";
        case State::Transcribing:     return "Transcribing";
        case State::Normalizing:      return "Normalizing";
        case State::Injecting:        return "Injecting";
        case State::SecureInput:      return "SecureInput";
        case State::TapDead:          return "TapDead";
    }
    return "?";
}

const char * state_detail(State s) {
    switch (s) {
        case State::NeedsPermissions: return "Permissions needed";
        case State::Idle:             return "Ready (mic asleep)";
        case State::Arming:           return "Waking mic…";
        case State::Armed:            return "Ready";
        case State::Recording:        return "Listening…";
        case State::Transcribing:     return "Transcribing…";
        case State::Normalizing:      return "Cleaning up…";
        case State::Injecting:        return "Inserting…";
        case State::SecureInput:      return "Blocked: secure input active";
        case State::TapDead:          return "Hotkey stopped working — restart Yap";
    }
    return "?";
}

}  // namespace yap
