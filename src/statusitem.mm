#import "statusitem.h"

#include "permissions.h"
#include "settings.h"
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
//
// A person speaking, not a microphone: a mic glyph in a menu bar reads as a
// mute toggle -- something you click to turn your input on or off -- which is
// not what this is. person.wave.2 is a head-and-shoulders silhouette with speech
// coming out of it, and its outline/fill pair carries idle vs. recording without
// a second glyph.
static NSString * symbol_for(yap::State s) {
    switch (s) {
        case yap::State::NeedsPermissions: return @"exclamationmark.triangle";
        case yap::State::Idle:             return @"person.wave.2";
        case yap::State::Arming:           return @"person.wave.2";
        case yap::State::Armed:            return @"person.wave.2";
        case yap::State::Recording:        return @"person.wave.2.fill";
        case yap::State::Transcribing:     return @"waveform";
        case yap::State::Normalizing:      return @"wand.and.stars";
        case yap::State::Injecting:        return @"text.cursor";
        case yap::State::SecureInput:      return @"lock.fill";
        case yap::State::TapDead:          return @"exclamationmark.triangle.fill";
    }
    return @"person.wave.2";
}

- (void)setState:(yap::State)s {
    _state = s;
    NSString * name = symbol_for(s);
    NSImage * img = [NSImage imageWithSystemSymbolName:name
                             accessibilityDescription:@(yap::state_detail(s))];
    if (!img) img = [NSImage imageWithSystemSymbolName:@"person.wave.2"
                             accessibilityDescription:@"Yap"];
    [img setTemplate:YES];   // setter, not dot-syntax: `template` is a C++ keyword
    _item.button.image = img;
    _item.button.toolTip = [NSString stringWithFormat:@"Yap — %s", yap::state_detail(s)];
    // Recording is the one state worth making unmistakable at a glance, and the
    // only one that gets a tint.
    //
    // Arming deliberately gets NONE. Dimming it with tertiaryLabelColor looked
    // washed out on a dark menu bar: the label colors are low-alpha white there,
    // so a tinted template glyph turns muddy grey next to the crisp system
    // indicators. Any alpha-based dim has that problem by construction, and the
    // state lasts ~300 ms -- not worth a second visual just to say "wait".
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

    // --- style: real model inputs (the control line), not cosmetics ---
    const yap::Style st = yap::settings::style();

    NSMenuItem * styleRoot = [[NSMenuItem alloc] initWithTitle:@"Style" action:nil keyEquivalent:@""];
    NSMenu * styleMenu = [[NSMenu alloc] init];
    struct { const char * label; int tag; } stylings[] = {
        {"Casual", 0}, {"Semi-casual", 1}, {"Semi-formal", 2}, {"Formal", 3}
    };
    for (auto & o : stylings) {
        NSMenuItem * it = [[NSMenuItem alloc] initWithTitle:@(o.label)
                                                     action:@selector(pickStyling:) keyEquivalent:@""];
        it.target = self; it.tag = o.tag;
        it.state = ((int) st.styling == o.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        [styleMenu addItem:it];
    }
    styleRoot.submenu = styleMenu;
    [m addItem:styleRoot];

    NSMenuItem * structRoot = [[NSMenuItem alloc] initWithTitle:@"Structure" action:nil keyEquivalent:@""];
    NSMenu * structMenu = [[NSMenu alloc] init];
    struct { const char * label; int tag; } structs[] = {{"Prose", 0}, {"Lists", 1}};
    for (auto & o : structs) {
        NSMenuItem * it = [[NSMenuItem alloc] initWithTitle:@(o.label)
                                                     action:@selector(pickStructure:) keyEquivalent:@""];
        it.target = self; it.tag = o.tag;
        it.state = ((int) st.structure == o.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        [structMenu addItem:it];
    }
    structRoot.submenu = structMenu;
    [m addItem:structRoot];

    NSMenuItem * ctxRoot = [[NSMenuItem alloc] initWithTitle:@"Context" action:nil keyEquivalent:@""];
    NSMenu * ctxMenu = [[NSMenu alloc] init];
    struct { const char * label; int tag; } ctxs[] = {{"General", 0}, {"Email", 1}};
    for (auto & o : ctxs) {
        NSMenuItem * it = [[NSMenuItem alloc] initWithTitle:@(o.label)
                                                     action:@selector(pickContext:) keyEquivalent:@""];
        it.target = self; it.tag = o.tag;
        it.state = ((int) st.context == o.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        [ctxMenu addItem:it];
    }
    ctxRoot.submenu = ctxMenu;
    [m addItem:ctxRoot];

    NSMenuItem * login = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                    action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = yap::settings::launch_at_login() ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:login];

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

- (void)pickStyling:(NSMenuItem *)it {
    yap::settings::set_styling((yap::Style::Styling) it.tag);
    [self refreshMenu];
}
- (void)pickStructure:(NSMenuItem *)it {
    yap::settings::set_structure((yap::Style::Structure) it.tag);
    [self refreshMenu];
}
- (void)pickContext:(NSMenuItem *)it {
    yap::settings::set_context((yap::Style::Context) it.tag);
    [self refreshMenu];
}
- (void)toggleLogin:(NSMenuItem *)it {
    yap::settings::set_launch_at_login(!yap::settings::launch_at_login());
    [self refreshMenu];
}

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
