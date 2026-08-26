#pragma once
#ifdef __OBJC__
#import <AppKit/AppKit.h>
#include "state.h"

// Menu-bar presence. Deliberately reflects the failure states (missing
// permissions, secure input, dead tap) as first-class icons -- those three are
// the app's entire support surface, so they must be visible without digging.
@interface YapStatusItem : NSObject
- (instancetype)init;
- (void)setState:(yap::State)s;
- (void)refreshMenu;
@end
#endif
