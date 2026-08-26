#pragma once
#include <functional>
#include <cstdint>

namespace yap {

// Tag stamped into every event we synthesize (Cmd+V for injection), so our own
// tap can recognize and ignore them. Without this, injecting text feeds our
// keystrokes straight back into our own hotkey handler.
constexpr int64_t kEventMagic = 0x7961700001LL;   // "yap" + 1

// F11. kVK_F11 == 0x67 == 103.
constexpr int64_t kKeycodeF11 = 103;

// A push-to-talk hotkey built on CGEventTap.
//
// CGEventTap rather than RegisterEventHotKey: the latter needs no TCC permission
// and does deliver key-up, but it only fires if the frontmost app declines the
// key first -- and editors/terminals (Zed, VS Code, Ghostty) claim every keyDown.
// "Doesn't work in my editor" is fatal for a dictation tool.
//
// Requires Accessibility (because we use kCGEventTapOptionDefault to SUPPRESS the
// key) and a running CFRunLoop on the calling thread.
class Hotkey {
public:
    // Called on the main thread. `down` is true on press, false on release.
    using Callback = std::function<void(bool down)>;

    ~Hotkey();

    bool start(Callback cb);
    void stop();

    // False once the tap has died and could not be revived.
    bool healthy() const { return healthy_; }

    // Internal, but must be reachable from the C callback.
    void handle_disabled();
    bool healthy_ = false;
    Callback cb_;

private:
    void * tap_    = nullptr;   // CFMachPortRef
    void * source_ = nullptr;   // CFRunLoopSourceRef
    void * timer_  = nullptr;   // __strong NSTimer, watchdog
};

}  // namespace yap
