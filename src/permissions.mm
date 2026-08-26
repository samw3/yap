#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

#include "permissions.h"
#include "log.h"

namespace yap {

const char * perm_name(Perm p) {
    switch (p) {
        case Perm::Granted: return "granted";
        case Perm::Denied:  return "denied";
        case Perm::Unknown: return "not-yet-asked";
    }
    return "?";
}

Permissions permissions_check() {
    Permissions p;

    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
        case AVAuthorizationStatusAuthorized:    p.microphone = Perm::Granted; break;
        case AVAuthorizationStatusNotDetermined: p.microphone = Perm::Unknown; break;
        default:                                 p.microphone = Perm::Denied;  break;
    }

    // Accessibility is the superset we need: it covers a suppressing event tap
    // (kCGEventTapOptionDefault), CGEventPost, and the AX text-insertion path.
    // Per Apple DTS, an app with Accessibility automatically has Input
    // Monitoring, so there is deliberately no separate ListenEvent check here.
    // Pass NO for the prompt option so this stays pollable.
    p.accessibility = AXIsProcessTrustedWithOptions(nullptr) ? Perm::Granted : Perm::Denied;

    return p;
}

void permissions_request_microphone() {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL granted) {
        YAP_LOG("microphone request -> %{public}s", granted ? "granted" : "denied");
    }];
}

static void open_pane(NSString * anchor) {
    NSString * s = [@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:anchor];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:s]];
}

void permissions_open_accessibility_pane() { open_pane(@"Privacy_Accessibility"); }
void permissions_open_microphone_pane()    { open_pane(@"Privacy_Microphone"); }

bool secure_input_active() { return IsSecureEventInputEnabled(); }

}  // namespace yap
