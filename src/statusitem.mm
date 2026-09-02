#import "statusitem.h"

#import "update.h"
#import "appicon.h"

#include "permissions.h"
#include "settings.h"
#include "log.h"

#include <cmath>

@implementation YapStatusItem {
    NSStatusItem * _item;
    yap::State     _state;
    NSMenuItem *   _updateItem;        // re-titled in place while the menu is open
    BOOL           _updateActionable;
    BOOL           _updateCancellable;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _state = yap::State::NeedsPermissions;
    _item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _item.menu = [[NSMenu alloc] init];
    _item.menu.delegate = (id<NSMenuDelegate>) self;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(updaterChanged:)
                                               name:YapUpdaterDidChangeNotification
                                             object:nil];
    [self setState:_state];
    return self;
}

// SF Symbols as template images: no asset catalog, and they adapt to light/dark
// and to menu-bar tinting automatically.
//
// A person speaking, not a microphone: a mic glyph in a menu bar reads as a mute
// toggle. person.wave.2 is a head-and-shoulders silhouette with speech coming out
// of it, and its outline/fill pair carries idle vs. recording on one glyph.
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
    // No tint in any state. NSColor's dynamic colors resolve against the app's
    // appearance, and an LSUIElement app does not follow the menu bar's, so a tint
    // fights whichever bar it lands on. Template rendering matches it for free,
    // outline vs. fill already distinguishes recording, and macOS raises its own
    // amber mic indicator beside us whenever the input is live.
    _item.button.contentTintColor = nil;
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

    // --- updates: a row only when there is something to say ---
    [self appendUpdateItemsTo:m];

    // --- style: real model inputs (the control line), not cosmetics ---
    const yap::Style st = yap::settings::style();

    // Styling sits inline in the root menu, not behind a "Style" submenu: it is the
    // one axis worth changing mid-session, and inline items show which is active
    // without a hover. Separators fence the group -- the one opening it is emitted
    // by the permissions block above, or by the update block when it drew a row.
    struct { const char * label; int tag; } stylings[] = {
        {"Casual", 0}, {"Semi-casual", 1}, {"Semi-formal", 2}, {"Formal", 3}
    };
    for (auto & o : stylings) {
        NSMenuItem * it = [[NSMenuItem alloc] initWithTitle:@(o.label)
                                                     action:@selector(pickStyling:) keyEquivalent:@""];
        it.target = self; it.tag = o.tag;
        it.state = ((int) st.styling == o.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        [m addItem:it];
    }

    [m addItem:[NSMenuItem separatorItem]];

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

    // Everything below the style axes is set once and left alone, so it lives one
    // level down rather than lengthening the root menu. The urgent update rows are
    // not in here -- those still surface at the top, where they can be seen without
    // a hover.
    NSMenuItem * settingsRoot = [[NSMenuItem alloc] initWithTitle:@"Settings" action:nil keyEquivalent:@""];
    NSMenu * settingsMenu = [[NSMenu alloc] init];

    NSMenuItem * login = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                    action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = yap::settings::launch_at_login() ? NSControlStateValueOn : NSControlStateValueOff;
    [settingsMenu addItem:login];

    // How long the mic stays open between presses. Offered as durations rather
    // than an on/off switch because the setting has always been one, and because
    // the trade it makes is a matter of degree: a longer wait keeps the first
    // press of a burst instant, a shorter one gets the amber indicator off the
    // menu bar sooner. "Never" is the one qualitative choice, and it costs more
    // than it looks like -- hence the tooltip.
    NSMenuItem * sleepRoot = [[NSMenuItem alloc] initWithTitle:@"Microphone Sleep" action:nil keyEquivalent:@""];
    NSMenu * sleepMenu = [[NSMenu alloc] init];
    // Tolerant compare: a value hand-written with `defaults write` should still
    // tick the row it matches rather than leaving the submenu blank.
    const long idle = std::lround(yap::settings::idle_timeout());
    struct { const char * label; long seconds; } sleeps[] = {
        {"After 1 Minute", 60}, {"After 15 Minutes", 900}, {"After 1 Hour", 3600}, {"Never", 0}
    };
    for (auto & o : sleeps) {
        NSMenuItem * it = [[NSMenuItem alloc] initWithTitle:@(o.label)
                                                     action:@selector(pickIdleTimeout:) keyEquivalent:@""];
        it.target = self; it.tag = (NSInteger) o.seconds;
        it.state = (idle == o.seconds) ? NSControlStateValueOn : NSControlStateValueOff;
        if (o.seconds == 0)
            it.toolTip = @"Holds the microphone open until the screen locks or the Mac sleeps. "
                          "The amber recording indicator stays lit the whole time, and macOS will "
                          "not idle-sleep while it is.";
        [sleepMenu addItem:it];
    }
    sleepRoot.submenu = sleepMenu;
    [settingsMenu addItem:sleepRoot];

    [settingsMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem * autoUpd = [[NSMenuItem alloc] initWithTitle:@"Check for Updates Automatically"
                                                      action:@selector(toggleAutoUpdate:) keyEquivalent:@""];
    autoUpd.target = self;
    autoUpd.state = yap::settings::auto_update_check() ? NSControlStateValueOn : NSControlStateValueOff;
    // The only network access in the app, so the toggle says so on hover rather
    // than leaving someone to guess what "automatically" reaches out to.
    autoUpd.toolTip = @"Once a day, asks api.github.com whether a newer release exists. "
                       "This is the only network request Yap makes.";
    [settingsMenu addItem:autoUpd];

    NSMenuItem * checkNow = [[NSMenuItem alloc] initWithTitle:@"Check for Updates Now…"
                                                       action:@selector(checkForUpdates:) keyEquivalent:@""];
    checkNow.target = self;
    [settingsMenu addItem:checkNow];

    settingsRoot.submenu = settingsMenu;
    [m addItem:settingsRoot];

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
- (void)pickIdleTimeout:(NSMenuItem *)it {
    yap::settings::set_idle_timeout((double) it.tag);
    [self refreshMenu];
}
- (void)toggleLogin:(NSMenuItem *)it {
    yap::settings::set_launch_at_login(!yap::settings::launch_at_login());
    [self refreshMenu];
}

#pragma mark - updates

// Nothing is drawn unless the updater has something to report, so the menu of an
// up-to-date copy looks exactly as it did before updates existed.
- (void)appendUpdateItemsTo:(NSMenu *)m {
    YapUpdater * up = YapUpdater.shared;
    NSString * line = [up menuLine];
    _updateItem = nil;
    if (!line) return;

    _updateActionable  = [up menuLineIsActionable];
    _updateCancellable = [up canCancel];
    _updateItem = [[NSMenuItem alloc] initWithTitle:line
                                             action:_updateActionable ? @selector(installUpdate:) : nil
                                      keyEquivalent:@""];
    _updateItem.target = self;
    _updateItem.enabled = _updateActionable;
    _updateItem.toolTip = up.failureReason;
    [m addItem:_updateItem];

    if (_updateCancellable) {
        NSMenuItem * stop = [[NSMenuItem alloc] initWithTitle:@"Stop Download"
                                                       action:@selector(stopDownload:) keyEquivalent:@""];
        stop.target = self;
        [m addItem:stop];
    }
    if (up.availableVersion.length && up.releasePage) {
        NSMenuItem * notes = [[NSMenuItem alloc] initWithTitle:@"Release Notes…"
                                                        action:@selector(openReleaseNotes:) keyEquivalent:@""];
        notes.target = self;
        [m addItem:notes];
    }
    [m addItem:[NSMenuItem separatorItem]];
}

// A download posts progress twice a second, and rebuilding the whole menu under
// an open one is jarring. Re-title the row in place while its shape holds, and
// fall back to a rebuild only when a row appears, disappears, or changes what
// clicking it does.
- (void)updaterChanged:(NSNotification *)n {
    YapUpdater * up = YapUpdater.shared;
    NSString * line = [up menuLine];
    if (_updateItem && line
        && [up menuLineIsActionable] == _updateActionable
        && [up canCancel] == _updateCancellable) {
        _updateItem.title = line;
        _updateItem.toolTip = up.failureReason;
        return;
    }
    [self refreshMenu];
}

- (void)installUpdate:(id)sender { [YapUpdater.shared installAvailableUpdate]; }

- (void)stopDownload:(id)sender { [YapUpdater.shared cancelDownload]; }

- (void)openReleaseNotes:(id)sender {
    NSURL * u = YapUpdater.shared.releasePage;
    if (u) [NSWorkspace.sharedWorkspace openURL:u];
}

- (void)checkForUpdates:(id)sender { [YapUpdater.shared checkNow]; }

- (void)toggleAutoUpdate:(NSMenuItem *)it {
    const bool on = !yap::settings::auto_update_check();
    yap::settings::set_auto_update_check(on);
    [self refreshMenu];
    // Turning it on is itself a request to look now, rather than tomorrow.
    if (on) [YapUpdater.shared checkInBackground];
}

- (void)showAbout:(id)sender {
    // The s1-mini license carries a naming clause: the model must be credited as
    // "S1-mini by Superwhisper" with exact capitalization wherever deployed.
    NSAlert * a = [[NSAlert alloc] init];
    NSImage * icon = yap_app_icon();
    if (icon) a.icon = icon;
    a.messageText = [NSString stringWithFormat:@"Yap %@",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];
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
