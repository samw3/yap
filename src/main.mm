#import <AppKit/AppKit.h>
#import "app.h"

int main(int argc, const char ** argv) {
    @autoreleasepool {
        NSApplication * app = [NSApplication sharedApplication];
        YapAppDelegate * delegate = [[YapAppDelegate alloc] init];
        app.delegate = delegate;
        // Keep a strong reference: NSApplication holds `delegate` weakly.
        static YapAppDelegate * keepalive;
        keepalive = delegate;
        [app run];
    }
    return 0;
}
