#import "app.h"
#import "statusitem.h"

#include "log.h"
#include "permissions.h"
#include "state.h"

@implementation YapAppDelegate {
    YapStatusItem * _status;
    NSTimer       * _permPoll;
    yap::State      _state;
    BOOL            _stateValid;   // _state zero-inits to NeedsPermissions, which is a
                                   // real state -- without this the first transition
                                   // into it is silently swallowed.
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    // Belt and braces alongside LSUIElement in Info.plist. Critically this must
    // resolve to Accessory and never Prohibited: NSApplicationActivationPolicyProhibited
    // (what LSBackgroundOnly sets) makes CGEventTapCreate() return NULL even with
    // Accessibility granted and AXIsProcessTrusted() true.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    NSString * bid = [[NSBundle mainBundle] bundleIdentifier];
    YAP_LOG("yap starting: bundle=%{public}s path=%{public}s",
            bid ? bid.UTF8String : "<none>",
            [[NSBundle mainBundle] bundlePath].UTF8String);
    if (!bid) {
        // Unbundled: TCC attributes permissions to the launching process (the
        // terminal), which "works" and then fails when launched normally.
        YAP_FAULT("no bundle identifier — run the .app via `open`, not the bare binary");
    }

    _status = [[YapStatusItem alloc] init];

    // Always report the starting position once, unconditionally.
    const yap::Permissions p0 = yap::permissions_check();
    YAP_LOG("permissions at launch: mic=%{public}s accessibility=%{public}s",
            yap::perm_name(p0.microphone), yap::perm_name(p0.accessibility));

    [self reevaluate];

    // Neither Accessibility nor Input Monitoring has a change notification, so
    // polling is the only option. Poll only while something is missing.
    _permPoll = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                repeats:YES
                                                  block:^(NSTimer * t) { [self reevaluate]; }];
}

- (void)reevaluate {
    const yap::Permissions p = yap::permissions_check();
    yap::State next = p.ok() ? yap::State::Idle : yap::State::NeedsPermissions;

    if (!_stateValid || next != _state) {
        _stateValid = YES;
        YAP_LOG("state %{public}s -> %{public}s (mic=%{public}s ax=%{public}s)",
                yap::state_name(_state), yap::state_name(next),
                yap::perm_name(p.microphone), yap::perm_name(p.accessibility));
        _state = next;
        [_status setState:_state];
    }

    if (p.ok() && _permPoll) {
        // Stop the poll once we are fully granted; later phases own state from here.
        [_permPoll invalidate];
        _permPoll = nil;
        YAP_LOG("permissions complete; stopping permission poll");
    }
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [_permPoll invalidate];
    YAP_LOG("yap terminating");
}

@end
