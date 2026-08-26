#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

#include "hotkey.h"
#include "log.h"

#include <unistd.h>

namespace yap {

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type,
                               CGEventRef event, void * ud) {
    auto * hk = static_cast<Hotkey *>(ud);

    // FIRST branch, always: these two are not real events and carry no keycode.
    // A tap disabled by timeout stays dead until explicitly re-enabled, which
    // would silently break the hotkey forever.
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        YAP_WARN("event tap disabled (%{public}s) — re-enabling",
                 type == kCGEventTapDisabledByTimeout ? "timeout" : "user input");
        hk->handle_disabled();
        return event;
    }

    if (type != kCGEventKeyDown && type != kCGEventKeyUp) return event;

    // Ignore anything we synthesized ourselves (injection posts Cmd+V).
    const int64_t magic = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    if (magic == kEventMagic) return event;
    const int64_t pid = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
    if (pid == (int64_t) getpid()) return event;

    if (CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) != kKeycodeF11) return event;

    // Holding a key repeats keyDown; we only care about the edges.
    if (type == kCGEventKeyDown && CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0) {
        return nullptr;   // still swallow it
    }

    const bool down = (type == kCGEventKeyDown);

    // The callback must do essentially nothing. WindowServer disables taps whose
    // callback is slow, and the threshold is undocumented -- so hop to the main
    // queue and return immediately. Never do work inline here.
    Hotkey::Callback cb = hk->cb_;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(down); });

    // Swallow both edges. Passing only one through leaves apps with an orphan
    // keyUp, which Electron and Java apps mishandle.
    return nullptr;
}

Hotkey::~Hotkey() { stop(); }

bool Hotkey::start(Callback cb) {
    cb_ = std::move(cb);

    const CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);

    CFMachPortRef tap = CGEventTapCreate(
        kCGSessionEventTap,          // session, not HID: HID nominally wants root
        kCGHeadInsertEventTap,       // ahead of other taps and app delivery
        kCGEventTapOptionDefault,    // NOT ListenOnly -- required to return NULL
        mask, tap_callback, this);

    if (!tap) {
        // Almost always missing Accessibility. The other classic cause is an
        // activation policy of Prohibited (LSBackgroundOnly), which we avoid.
        YAP_WARN("CGEventTapCreate returned NULL — Accessibility not granted?");
        healthy_ = false;
        return false;
    }

    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    // Common modes, not default: otherwise the tap goes quiet during modal and
    // menu-tracking run loops.
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);

    tap_ = (void *) tap;
    source_ = (void *) src;
    healthy_ = true;

    // Watchdog. A tap can be non-NULL yet permanently inert with no
    // tapDisabled callback -- seen after re-signing, sleep/wake, and fast user
    // switching. Polling CGEventTapIsEnabled is the only way to notice.
    NSTimer * t = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                 repeats:YES
                                                   block:^(NSTimer * _) {
        if (!tap_) return;
        if (!CGEventTapIsEnabled((CFMachPortRef) tap_)) {
            YAP_WARN("event tap found disabled by watchdog — re-enabling");
            CGEventTapEnable((CFMachPortRef) tap_, true);
            if (!CGEventTapIsEnabled((CFMachPortRef) tap_)) {
                YAP_FAULT("event tap could not be revived");
                healthy_ = false;
            }
        }
    }];
    timer_ = (void *) CFBridgingRetain(t);

    YAP_LOG("event tap installed (F11, keycode %lld, suppressing)", (long long) kKeycodeF11);
    return true;
}

void Hotkey::handle_disabled() {
    if (tap_) CGEventTapEnable((CFMachPortRef) tap_, true);
}

void Hotkey::stop() {
    if (timer_) {
        NSTimer * t = (NSTimer *) CFBridgingRelease(timer_);
        [t invalidate];
        timer_ = nullptr;
    }
    if (source_) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), (CFRunLoopSourceRef) source_, kCFRunLoopCommonModes);
        CFRelease((CFRunLoopSourceRef) source_);
        source_ = nullptr;
    }
    if (tap_) {
        CGEventTapEnable((CFMachPortRef) tap_, false);
        CFRelease((CFMachPortRef) tap_);
        tap_ = nullptr;
    }
    healthy_ = false;
}

}  // namespace yap
