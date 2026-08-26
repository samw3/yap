#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

#include "inject.h"
#include "hotkey.h"   // kEventMagic
#include "log.h"

#include <vector>

namespace yap {

// Timings from production dictation tools. 50 ms before the paste lets the
// pasteboard settle; the restore delay must be >= ~100 ms because at 50 ms a busy
// target app has not consumed the paste yet and the user gets their OLD clipboard.
static const NSTimeInterval kPrePasteDelay     = 0.050;
static const NSTimeInterval kRestoreDelay      = 0.150;

// ---- pasteboard snapshot -----------------------------------------------------
// clearContents invalidates NSPasteboardItem objects, so a saved item cannot be
// re-added. The only correct save is a deep copy of every type's data.
struct PasteItem { std::vector<std::pair<NSString *, NSData *>> types; };

static NSArray<NSPasteboardItem *> * snapshot(NSPasteboard * pb) {
    NSMutableArray * saved = [NSMutableArray array];
    for (NSPasteboardItem * item in pb.pasteboardItems) {
        NSPasteboardItem * copy = [[NSPasteboardItem alloc] init];
        BOOL any = NO;
        for (NSPasteboardType t in item.types) {
            NSData * d = [item dataForType:t];
            if (d) { [copy setData:d forType:t]; any = YES; }
        }
        if (any) [saved addObject:copy];
    }
    return saved;
}

// ---- AX fast path ------------------------------------------------------------
// Setting kAXSelectedTextAttribute inserts at the caret without touching the
// clipboard or the keyboard, and works in Raycast/Spotlight where Cmd+V is
// intercepted. But it returns kAXErrorSuccess even when the write silently does
// nothing, so it is gated to single-line input roles. AXTextArea -- every
// terminal and code editor -- accepts the write and discards the text, because
// those views process input as a key-event stream, not a value mutation.
static bool try_ax_insert(const std::string & text) {
    AXUIElementRef sys = AXUIElementCreateSystemWide();
    if (!sys) return false;

    CFTypeRef focused = nullptr;
    AXError err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute, &focused);
    CFRelease(sys);
    if (err != kAXErrorSuccess || !focused) return false;
    if (CFGetTypeID(focused) != AXUIElementGetTypeID()) { CFRelease(focused); return false; }
    AXUIElementRef el = (AXUIElementRef) focused;

    CFTypeRef roleRef = nullptr;
    bool allowed = false;
    if (AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &roleRef) == kAXErrorSuccess && roleRef) {
        if (CFGetTypeID(roleRef) == CFStringGetTypeID()) {
            NSString * role = (__bridge NSString *) roleRef;
            allowed = [role isEqualToString:(__bridge NSString *) kAXTextFieldRole]
                   || [role isEqualToString:@"AXSearchField"]
                   || [role isEqualToString:(__bridge NSString *) kAXComboBoxRole];
            if (!allowed) YAP_INFO("AX role %{public}s not whitelisted — using clipboard",
                                   role.UTF8String);
        }
        CFRelease(roleRef);
    }
    if (!allowed) { CFRelease(el); return false; }

    NSString * s = [NSString stringWithUTF8String:text.c_str()];
    if (!s) { CFRelease(el); return false; }
    const AXError set = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute,
                                                     (__bridge CFTypeRef) s);
    CFRelease(el);
    if (set != kAXErrorSuccess) return false;
    YAP_INFO("inserted via AX fast path");
    return true;
}

// ---- Cmd+V ------------------------------------------------------------------
static void post_cmd_v() {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef down = CGEventCreateKeyboardEvent(src, (CGKeyCode) kVK_ANSI_V, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(src, (CGKeyCode) kVK_ANSI_V, false);
    if (down && up) {
        // Flags on BOTH edges: some apps see a stuck or absent Cmd otherwise.
        CGEventSetFlags(down, kCGEventFlagMaskCommand);
        CGEventSetFlags(up,   kCGEventFlagMaskCommand);
        // Tag so our own event tap ignores these.
        CGEventSetIntegerValueField(down, kCGEventSourceUserData, kEventMagic);
        CGEventSetIntegerValueField(up,   kCGEventSourceUserData, kEventMagic);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
    }
    if (down) CFRelease(down);
    if (up)   CFRelease(up);
    if (src)  CFRelease(src);
}

InjectResult inject_text(const std::string & text) {
    if (text.empty()) return InjectResult::Ok;

    // Never inject into a secure field, even if we somehow could.
    if (IsSecureEventInputEnabled()) {
        YAP_WARN("secure input active — refusing to inject");
        return InjectResult::BlockedSecureInput;
    }

    if (try_ax_insert(text)) return InjectResult::Ok;

    NSPasteboard * pb = [NSPasteboard generalPasteboard];
    NSArray<NSPasteboardItem *> * saved = snapshot(pb);

    NSString * s = [NSString stringWithUTF8String:text.c_str()];
    if (!s) { YAP_WARN("text was not valid UTF-8"); return InjectResult::Failed; }

    [pb clearContents];
    if (![pb setString:s forType:NSPasteboardTypeString]) {
        YAP_WARN("could not write pasteboard");
        return InjectResult::Failed;
    }
    // Ask well-behaved clipboard managers (Maccy, Raycast, Paste) not to archive
    // dictated text into their history.
    [pb setData:[NSData data] forType:@"org.nspasteboard.ConcealedType"];

    const NSInteger afterWrite = pb.changeCount;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPrePasteDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        post_cmd_v();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRestoreDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // If anything else touched the pasteboard meanwhile (a clipboard
            // manager, the user copying), restoring would eat their copy.
            if (pb.changeCount != afterWrite) {
                YAP_INFO("pasteboard changed by someone else — leaving it alone");
                return;
            }
            [pb clearContents];
            if (saved.count > 0) [pb writeObjects:saved];
        });
    });

    return InjectResult::Ok;
}

}  // namespace yap
