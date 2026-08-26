#pragma once
#include <string>

namespace yap {

enum class InjectResult { Ok, BlockedSecureInput, Failed };

// Insert text into the frontmost app.
//
// Primary path is pasteboard + synthesized Cmd+V, not CGEventKeyboardSetUnicodeString:
// that API is capped around 20 UTF-16 units per event, needs real Return keycodes
// for newlines, and CGEvent.h itself warns frameworks may ignore the attached
// string and retranslate from the keycode -- which is what Chromium does, breaking
// every Electron app plus Terminal and Java. A 300-character transcript would also
// become ~600 ms of visibly stuttering typing.
//
// All injections are serialized: a delayed clipboard restore from one injection
// firing during the next would paste the wrong text.
InjectResult inject_text(const std::string & text);

}  // namespace yap
