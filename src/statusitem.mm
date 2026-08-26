#import "statusitem.h"

#include "permissions.h"
#include "log.h"

@implementation YapStatusItem {
    NSStatusItem * _item;
    yap::State     _state;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _state = yap::State::NeedsPermissions;
    _item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _item.menu = [[NSMenu alloc] init];
    _item.menu.delegate = (id<NSMenuDelegate>) self;
    [self setState:_state];
    return self;
}

// SF Symbols as template images: no asset catalog, and they adapt to light/dark
// and to menu-bar tinting automatically.
static NSString * symbol_for(yap::State s) {
    switch (s) {
        case yap::State::NeedsPermissions: return @"exclamationmark.triangle";
        case yap::State::Idle:             return @"mic";
        case yap::State::Arming:           return @"mic.badge.plus";
        case yap::State::Armed:            return @"mic";
        case yap::State::Recording:        return @"mic.fill";
        case yap::State::Transcribing:     return @"waveform";
        case yap::State::Normalizing:      return @"wand.and.stars";
        case yap::State::Injecting:        return @"text.cursor";
        case yap::State::SecureInput:      return @"lock.fill";
        case yap::State::TapDead:          return @"exclamationmark.triangle.fill";
    }
    return @"mic";
}

- (void)setState:(yap::State)s {
    _state = s;
    NSString * name = symbol_for(s);
    NSImage * img = [NSImage imageWithSystemSymbolName:name
                             accessibilityDescription:@(yap::state_detail(s))];
    if (!img) img = [NSImage imageWithSystemSymbolName:@"mic" accessibilityDescription:@"Yap"];
    [img setTemplate:YES];   // setter, not dot-syntax: `template` is a C++ keyword
    _item.button.image = img;
    _item.button.toolTip = [NSString stringWithFormat:@"Yap — %s", yap::state_detail(s)];
    // Recording is the one state worth making unmistakable at a glance.
    _item.button.contentTintColor =
        (s == yap::State::Recording) ? [NSColor systemRedColor] : nil;
    [self refreshMenu];
}

- (void)menuNeedsUpdate:(NSMenu *)menu { [self refreshMenu]; }

- (void)refreshMenu {
    NSMenu * m = _item.menu;
    [m removeAllItems];

    NSMenuItem * status = [[NSMenuItem alloc] initWithTitle:@(yap::state_detail(_state))
                                                     action:nil keyEquivalent:@""];
    status.enabled = NO;
    [m addItem:status];
    [m addItem:[NSMenuItem separatorItem]];

    const yap::Permissions p = yap::permissions_check();

    if (p.microphone != yap::Perm::Granted) {
        NSMenuItem * it = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"Microphone: %s — grant…", yap::perm_name(p.microphone)]
                   action:@selector(fixMic:) keyEquivalent:@""];
        it.target = self;
        [m addItem:it];
    }
    if (p.accessibility != yap::Perm::Granted) {
        NSMenuItem * it = [[NSMenuItem alloc]
            initWithTitle:@"Accessibility: denied — grant…"
                   action:@selector(fixAX:) keyEquivalent:@""];
        it.target = self;
        [m addItem:it];
    }
    if (p.ok()) {
        NSMenuItem * it = [[NSMenuItem alloc] initWithTitle:@"Hold F11 to dictate"
                                                     action:nil keyEquivalent:@""];
        it.enabled = NO;
        [m addItem:it];
    }

    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem * about = [[NSMenuItem alloc] initWithTitle:@"About Yap"
                                                    action:@selector(showAbout:) keyEquivalent:@""];
    about.target = self;
    [m addItem:about];

    NSMenuItem * quit = [[NSMenuItem alloc] initWithTitle:@"Quit Yap"
                                                   action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [m addItem:quit];
}

- (void)fixMic:(id)sender {
    const yap::Permissions p = yap::permissions_check();
    // Only the first ask shows a system alert; after a denial the alert never
    // reappears, so send the user to the pane instead of silently doing nothing.
    if (p.microphone == yap::Perm::Unknown) yap::permissions_request_microphone();
    else                                    yap::permissions_open_microphone_pane();
}

- (void)fixAX:(id)sender { yap::permissions_open_accessibility_pane(); }

- (void)showAbout:(id)sender {
    // The s1-mini license carries a naming clause: the model must be credited as
    // "S1-mini by Superwhisper" with exact capitalization wherever deployed.
    NSAlert * a = [[NSAlert alloc] init];
    a.messageText = @"Yap";
    a.informativeText =
        @"Push-to-talk dictation. Everything runs on-device.\n\n"
         "Transcription: Parakeet TDT 0.6B v3 (NVIDIA), ggml conversion by ggml-org.\n"
         "Normalization: S1-mini by Superwhisper — Apache 2.0 with a naming clause.\n\n"
         "Built on llama.cpp and whisper.cpp (MIT).";
    [a addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [a runModal];
}

@end
