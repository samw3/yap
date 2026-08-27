#pragma once
#ifdef __OBJC__
#import <AppKit/AppKit.h>

// The bundle's own icon, for anything that has to draw it.
//
// Alerts have to be handed this explicitly. NSAlert's default is the *named*
// system image NSApplicationIcon, which resolves through LaunchServices and
// comes back as the grey placeholder for an LSUIElement app, because there is no
// Dock tile behind it. Setting NSApp.applicationIconImage does not help -- the
// alert never asks for that one -- and the bundle is not at fault either: the
// same icns renders correctly through NSWorkspace at the same moment.
//
// Cheap enough to call per alert: NSImage does not decode an icns until it is
// drawn, and alerts are rare.
static inline NSImage * yap_app_icon(void) {
    NSBundle * b = NSBundle.mainBundle;
    // Read the name from the plist rather than hardcoding it, so this cannot
    // drift from CFBundleIconFile. The key is allowed to carry the extension.
    NSString * name = [[b objectForInfoDictionaryKey:@"CFBundleIconFile"]
                       stringByDeletingPathExtension];
    NSString * path = name.length ? [b pathForResource:name ofType:@"icns"] : nil;
    return path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
}
#endif
