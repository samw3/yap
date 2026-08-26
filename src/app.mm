#import "app.h"
#import "statusitem.h"
#import "audio.h"

#include "log.h"
#include "permissions.h"
#include "state.h"
#include "hotkey.h"
#include "wav.h"
#include "pipeline.h"
#include "inject.h"
#include "settings.h"

#include <memory>
#include <vector>

// Tunables. Pre-roll catches the very common case of starting to speak a hair
// before the key bottoms out.
static constexpr double kPreRollSeconds   = 0.30;
static constexpr double kIdleTimeout      = 60.0;   // 0 disables teardown
static constexpr double kDrainInterval    = 0.25;   // keep the ring well ahead of eviction
static constexpr double kMinHoldSeconds   = 0.20;   // shorter presses are accidental taps
static constexpr double kMaxHoldSeconds   = 120.0;

@implementation YapAppDelegate {
    YapStatusItem *                _status;
    YapAudio *                     _audio;
    std::unique_ptr<yap::Hotkey>   _hotkey;
    std::unique_ptr<yap::Pipeline> _pipe;

    NSTimer * _permPoll;
    NSTimer * _idleTimer;
    NSTimer * _drainTimer;

    yap::State _state;
    BOOL       _stateValid;

    // Recording
    BOOL               _recording;
    uint64_t           _startFrame;
    NSDate *           _pressedAt;
    std::vector<float> _utterance;    // mono at hardware rate
    uint64_t           _cursor;
    uint64_t           _armGen;       // engine generation _cursor is expressed in
    double             _utteranceRate;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    // Must resolve to Accessory, never Prohibited: Prohibited (what
    // LSBackgroundOnly sets) makes CGEventTapCreate() return NULL even with
    // Accessibility granted and AXIsProcessTrusted() true.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    NSString * bid = [[NSBundle mainBundle] bundleIdentifier];
    YAP_LOG("yap starting: bundle=%{public}s path=%{public}s",
            bid ? bid.UTF8String : "<none>",
            [[NSBundle mainBundle] bundlePath].UTF8String);
    if (!bid) YAP_FAULT("no bundle identifier — run the .app via `open`, not the bare binary");

    _status = [[YapStatusItem alloc] init];
    _audio  = [[YapAudio alloc] init];

    const yap::Permissions p0 = yap::permissions_check();
    YAP_LOG("permissions at launch: mic=%{public}s accessibility=%{public}s",
            yap::perm_name(p0.microphone), yap::perm_name(p0.accessibility));

    [self reevaluate];

    [self startPipeline];
    [self observeSystemEvents];

    _permPoll = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES
                                                  block:^(NSTimer * t) { [self reevaluate]; }];
}

- (void)startPipeline {
    NSBundle * b = [NSBundle mainBundle];
    NSString * asr = [b pathForResource:@"ggml-parakeet-tdt-0.6b-v3-q8_0" ofType:@"bin"];
    NSString * llm = [b pathForResource:@"s1-mini-q4_k_m" ofType:@"gguf"];
    if (!asr || !llm) {
        YAP_FAULT("models missing from bundle Resources (asr=%{public}s llm=%{public}s)",
                  asr ? "ok" : "MISSING", llm ? "ok" : "MISSING");
        return;
    }
    _pipe = std::make_unique<yap::Pipeline>();
    // Loads and warms on the worker thread; app launch is not blocked. Doing the
    // warm-up now converts a 1-3 s first-request stall into zero.
    _pipe->start(asr.UTF8String, llm.UTF8String, [](bool ok) {
        YAP_LOG("pipeline start -> %{public}s", ok ? "ready" : "FAILED");
    });
}

#pragma mark - system events

- (void)observeSystemEvents {
    NSNotificationCenter * wc = [[NSWorkspace sharedWorkspace] notificationCenter];
    __weak YapAppDelegate * weakSelf = self;

    // Event taps and audio engines both die across sleep/wake and fast user
    // switching, often with no callback at all -- so tear down deliberately on
    // the way out and rebuild on the way back in.
    void (^teardown)(NSNotification *) = ^(NSNotification * n) {
        YapAppDelegate * s = weakSelf; if (!s) return;
        YAP_LOG("system event %{public}s — releasing audio and tap", n.name.UTF8String);
        [s abortRecording];
        [s->_audio disarm];
        if (s->_hotkey) { s->_hotkey->stop(); s->_hotkey.reset(); }
        [s setState:yap::State::Idle];
    };
    void (^rebuild)(NSNotification *) = ^(NSNotification * n) {
        YapAppDelegate * s = weakSelf; if (!s) return;
        YAP_LOG("system event %{public}s — rebuilding tap", n.name.UTF8String);
        [s reevaluate];   // reinstalls the hotkey; audio re-arms lazily on next press
    };

    for (NSString * name in @[NSWorkspaceWillSleepNotification,
                              NSWorkspaceSessionDidResignActiveNotification,
                              NSWorkspaceScreensDidSleepNotification]) {
        [wc addObserverForName:name object:nil queue:nil usingBlock:teardown];
    }
    for (NSString * name in @[NSWorkspaceDidWakeNotification,
                              NSWorkspaceSessionDidBecomeActiveNotification]) {
        [wc addObserverForName:name object:nil queue:nil usingBlock:rebuild];
    }
}

- (void)abortRecording {
    if (!_recording) return;
    YAP_LOG("aborting in-flight recording");
    _recording = NO;
    [_drainTimer invalidate]; _drainTimer = nil;
    _utterance.clear();
}

#pragma mark - permissions / lifecycle

- (void)reevaluate {
    const yap::Permissions p = yap::permissions_check();

    if (!p.ok()) {
        [self setState:yap::State::NeedsPermissions];
        return;
    }

    if (!_hotkey) {
        _hotkey = std::make_unique<yap::Hotkey>();
        __weak YapAppDelegate * weakSelf = self;
        if (!_hotkey->start([weakSelf](bool down) {
                YapAppDelegate * s = weakSelf;
                if (s) down ? [s onKeyDown] : [s onKeyUp];
            })) {
            _hotkey.reset();
            YAP_WARN("hotkey install failed; will retry");
            [self setState:yap::State::NeedsPermissions];
            return;
        }
        YAP_LOG("hotkey ready — hold F11 to dictate");
        // Microphone permission is still only "granted" on paper until we open a
        // device; the first arm is what proves it.
    }

    if (_hotkey && !_hotkey->healthy()) { [self setState:yap::State::TapDead]; return; }

    if (!_recording) {
        [self setState:[_audio isArmed] ? yap::State::Armed : yap::State::Idle];
    }

    if (_permPoll) { [_permPoll invalidate]; _permPoll = nil;
                     YAP_LOG("permissions complete; stopping permission poll"); }
}

- (void)setState:(yap::State)s {
    if (_stateValid && s == _state) return;
    YAP_LOG("state %{public}s -> %{public}s",
            _stateValid ? yap::state_name(_state) : "(init)", yap::state_name(s));
    _state = s;
    _stateValid = YES;
    [_status setState:s];
}

#pragma mark - hotkey

- (void)onKeyDown {
    if (_recording) return;

    // While secure input is on we receive no key events at all, so seeing this
    // key press means it is off -- but check anyway, since it can turn on between
    // press and release and we must not inject into a password field.
    if (yap::secure_input_active()) {
        YAP_WARN("secure input active — ignoring press");
        [self setState:yap::State::SecureInput];
        return;
    }

    if (![_audio isArmed]) {
        [self setState:yap::State::Arming];
        if (![_audio arm]) {
            YAP_WARN("could not arm audio on key-down");
            [self setState:yap::State::Idle];
            return;
        }
    }

    const double rate = [_audio hardwareRate];
    const uint64_t now = [_audio framesWritten];
    const uint64_t preroll = (uint64_t)(kPreRollSeconds * rate);
    // On the first press after idling there is no buffered past, so pre-roll is
    // simply unavailable -- start at `now` rather than making the user wait.
    _startFrame = now > preroll ? now - preroll : 0;
    _cursor     = _startFrame;
    _armGen     = [_audio generation];
    _utteranceRate = rate;
    _utterance.clear();
    _pressedAt  = [NSDate date];
    _recording  = YES;

    [self cancelIdleTimer];
    [self setState:yap::State::Recording];

    _drainTimer = [NSTimer scheduledTimerWithTimeInterval:kDrainInterval repeats:YES
                                                    block:^(NSTimer * t) { [self drain]; }];
    YAP_INFO("recording from frame %llu (preroll %llu @ %.0f Hz)",
             (unsigned long long) _startFrame, (unsigned long long) preroll, rate);
}

// The frame timeline restarts at zero with every new engine, so a rebuild in the
// middle of a hold strands _cursor in a timeline that no longer exists: `now <=
// _cursor` then holds for the rest of the press and the hold yields zero frames
// with nothing logged. Re-anchor to the new engine instead, and keep whatever was
// already captured unless the hardware rate moved -- splicing 44.1 kHz onto
// 48 kHz would just come out wrong.
- (void)reanchorIfEngineRebuilt {
    const uint64_t gen = [_audio generation];
    if (gen == _armGen) return;

    const double   rate = [_audio hardwareRate];
    const uint64_t now  = [_audio framesWritten];
    if (rate != _utteranceRate && !_utterance.empty()) {
        YAP_WARN("engine rebuilt mid-hold at a new rate (%.0f -> %.0f Hz) — discarding "
                 "%zu frames captured before it", _utteranceRate, rate, _utterance.size());
        _utterance.clear();
    } else {
        YAP_WARN("engine rebuilt mid-hold (generation %llu -> %llu) — keeping %zu frames, "
                 "with a gap where the engine restarted",
                 (unsigned long long) _armGen, (unsigned long long) gen, _utterance.size());
    }
    _armGen        = gen;
    _utteranceRate = rate;
    _startFrame    = now;
    _cursor        = now;
}

- (void)drain {
    if (!_recording) return;
    [self reanchorIfEngineRebuilt];
    const uint64_t now = [_audio framesWritten];
    if (now <= _cursor) return;
    BOOL skipped = NO;
    if ([_audio copyRangeFrom:_cursor to:now into:&_utterance skipped:&skipped]) {
        if (skipped) YAP_WARN("ring evicted audio before drain — utterance has a gap");
        _cursor = now;
    }
    const double held = [[NSDate date] timeIntervalSinceDate:_pressedAt];
    if (held > kMaxHoldSeconds) {
        YAP_WARN("hold exceeded %.0f s — finishing early", kMaxHoldSeconds);
        [self onKeyUp];
    }
}

- (void)onKeyUp {
    if (!_recording) return;
    _recording = NO;
    [_drainTimer invalidate]; _drainTimer = nil;

    const double held = [[NSDate date] timeIntervalSinceDate:_pressedAt];
    [self drainFinal];

    if (held < kMinHoldSeconds) {
        YAP_INFO("press was %.0f ms — treating as an accidental tap", held * 1000);
        _utterance.clear();
        [self armedIdleAndSchedule];
        return;
    }

    [self setState:yap::State::Transcribing];

    std::vector<float> pcm16k;
    if (![_audio resampleTo16k:_utterance out:&pcm16k]) {
        YAP_WARN("resample failed — dropping utterance");
        [self armedIdleAndSchedule];
        return;
    }

    // Cheap energy gate: pressed the key and said nothing. No VAD model needed.
    double sumsq = 0;
    for (float s : pcm16k) sumsq += (double) s * s;
    const double rms = pcm16k.empty() ? 0.0 : sqrt(sumsq / pcm16k.size());

    YAP_LOG("captured %.2f s held, %zu hw frames -> %zu @16k, rms %.5f, signal=%{public}s",
            held, _utterance.size(), pcm16k.size(), rms,
            [_audio hasRealSignal] ? "yes" : "NONE");

    if (rms < 0.0005) {
        YAP_LOG("below energy gate — nothing said");
        [self armedIdleAndSchedule];
        return;
    }

    if (!_pipe || !_pipe->ready()) {
        YAP_WARN("pipeline not ready — dropping utterance");
        [self armedIdleAndSchedule];
        return;
    }

    __weak YapAppDelegate * weakSelf = self;
    _pipe->submit(std::move(pcm16k), yap::settings::style(),
        // on_stage: worker thread -> main
        [weakSelf](const char * stage) {
            NSString * st = @(stage);
            dispatch_async(dispatch_get_main_queue(), ^{
                YapAppDelegate * s = weakSelf; if (!s) return;
                [s setState:[st isEqualToString:@"transcribing"]
                            ? yap::State::Transcribing : yap::State::Normalizing];
            });
        },
        // on_done: worker thread -> main
        [weakSelf](yap::Result r) {
            dispatch_async(dispatch_get_main_queue(), ^{
                YapAppDelegate * s = weakSelf; if (!s) return;
                [s finish:r];
            });
        });

    // Deliberately NOT calling armedIdleAndSchedule here: the job is still in
    // flight. -finish: owns the transition back to Armed and starts the idle
    // countdown, otherwise the countdown begins before the work completes and the
    // menu-bar state briefly lies about what is happening.
    _utterance.clear();
}

- (void)drainFinal {
    [self reanchorIfEngineRebuilt];
    const uint64_t now = [_audio framesWritten];
    if (now > _cursor) {
        BOOL skipped = NO;
        [_audio copyRangeFrom:_cursor to:now into:&_utterance skipped:&skipped];
        _cursor = now;
    }
}

- (void)finish:(const yap::Result &)r {
    if (!r.ok || r.text.empty()) {
        YAP_LOG("nothing to insert");
        [self armedIdleAndSchedule];
        return;
    }

    [self setState:yap::State::Injecting];
    const yap::InjectResult ir = yap::inject_text(r.text);

    switch (ir) {
        case yap::InjectResult::Ok:
            YAP_LOG("inserted %zu chars%{public}s", r.text.size(),
                    r.normalized ? "" : " (raw transcript — normalizer declined)");
            [self armedIdleAndSchedule];
            break;
        case yap::InjectResult::BlockedSecureInput:
            [self setState:yap::State::SecureInput];
            [self scheduleIdleTimer];
            break;
        case yap::InjectResult::Failed:
            YAP_WARN("injection failed");
            [self armedIdleAndSchedule];
            break;
    }
}

#pragma mark - idle teardown

- (void)armedIdleAndSchedule {
    [self setState:[_audio isArmed] ? yap::State::Armed : yap::State::Idle];
    [self scheduleIdleTimer];
}

- (void)scheduleIdleTimer {
    [self cancelIdleTimer];
    const double timeout = yap::settings::idle_timeout();
    if (timeout <= 0) return;   // 0 == never tear down
    _idleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout repeats:NO
                                                   block:^(NSTimer * t) {
        if (self->_recording) return;
        YAP_LOG("idle %.0f s — tearing down audio (indicator and sleep assertion clear)",
                yap::settings::idle_timeout());
        [self->_audio disarm];
        [self setState:yap::State::Idle];
    }];
}

- (void)cancelIdleTimer { [_idleTimer invalidate]; _idleTimer = nil; }

- (void)applicationWillTerminate:(NSNotification *)note {
    [_permPoll invalidate];
    [_idleTimer invalidate];
    [_drainTimer invalidate];
    if (_hotkey) _hotkey->stop();
    if (_pipe) _pipe->stop();
    [_audio disarm];
    YAP_LOG("yap terminating");
}

@end
