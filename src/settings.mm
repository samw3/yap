#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>

#include "settings.h"
#include "log.h"

namespace yap { namespace settings {

static NSString * const kStyling   = @"yap.styling";
static NSString * const kStructure = @"yap.structure";
static NSString * const kContext   = @"yap.context";
static NSString * const kIdle      = @"yap.idleTimeout";

Style style() {
    NSUserDefaults * d = [NSUserDefaults standardUserDefaults];
    Style s;
    if ([d objectForKey:kStyling])   s.styling   = (Style::Styling)   [d integerForKey:kStyling];
    if ([d objectForKey:kStructure]) s.structure = (Style::Structure) [d integerForKey:kStructure];
    if ([d objectForKey:kContext])   s.context   = (Style::Context)   [d integerForKey:kContext];
    return s;
}

void set_styling(Style::Styling v) {
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger) v forKey:kStyling];
}
void set_structure(Style::Structure v) {
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger) v forKey:kStructure];
}
void set_context(Style::Context v) {
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger) v forKey:kContext];
}

double idle_timeout() {
    NSUserDefaults * d = [NSUserDefaults standardUserDefaults];
    return [d objectForKey:kIdle] ? [d doubleForKey:kIdle] : 60.0;
}
void set_idle_timeout(double s) {
    [[NSUserDefaults standardUserDefaults] setDouble:s forKey:kIdle];
}

// SMAppService, not the deprecated SMLoginItemSetEnabled / LSSharedFileList.
// Registers the app at its CURRENT location, so the bundle path must be stable.
bool launch_at_login() {
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    return false;
}

void set_launch_at_login(bool on) {
    if (@available(macOS 13.0, *)) {
        NSError * err = nil;
        BOOL ok = on ? [SMAppService.mainAppService registerAndReturnError:&err]
                     : [SMAppService.mainAppService unregisterAndReturnError:&err];
        if (!ok) YAP_WARN("launch-at-login %{public}s failed: %{public}s",
                          on ? "register" : "unregister",
                          err.localizedDescription.UTF8String);
        else YAP_LOG("launch at login -> %{public}s", on ? "on" : "off");
    }
}

}}  // namespace yap::settings
