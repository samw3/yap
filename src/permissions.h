#pragma once

namespace yap {

enum class Perm { Unknown, Denied, Granted };

struct Permissions {
    Perm microphone   = Perm::Unknown;
    Perm accessibility = Perm::Unknown;
    bool ok() const { return microphone == Perm::Granted && accessibility == Perm::Granted; }
};

// Non-prompting status read. Safe to poll.
Permissions permissions_check();

// Prompting variants. Microphone shows the system alert (needs
// NSMicrophoneUsageDescription); Accessibility cannot be granted
// programmatically, so this opens the pane and the user toggles it.
void permissions_request_microphone();
void permissions_open_accessibility_pane();
void permissions_open_microphone_pane();

const char * perm_name(Perm p);

// True when a password field has focus. While this is on, our event tap receives
// NO keyboard events at all -- we will not even see F11 -- and posted events are
// blocked. Detect and report; never try to work around it.
bool secure_input_active();

}  // namespace yap
