#import "app.h"
#import "statusitem.h"
#import "audio.h"

#include "log.h"
#include "permissions.h"
#include "state.h"
#include "hotkey.h"
#include "wav.h"

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
    YapStatusItem *              _status;
    YapAudio *                   _audio;
    std::unique_ptr<yap::Hotkey> _hotkey;

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

    _permPoll = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES
                                                  block:^(NSTimer * t) { [self reevaluate]; }];
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

- (void)drain {
    if (!_recording) return;
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

    // Phase 2 deliverable: dump to disk so capture can be verified independently
    // of the ASR and LLM stages.
    NSString * dir = [NSString stringWithFormat:@"%@/Library/Logs", NSHomeDirectory()];
    NSString * path = [NSString stringWithFormat:@"%@/yap-last-capture.wav", dir];
    if (yap::write_wav_16k_mono(path.UTF8String, pcm16k))
        YAP_LOG("wrote %{public}s", path.UTF8String);
    else
        YAP_WARN("failed writing %{public}s", path.UTF8String);

    _utterance.clear();
    [self armedIdleAndSchedule];
}

- (void)drainFinal {
    const uint64_t now = [_audio framesWritten];
    if (now > _cursor) {
        BOOL skipped = NO;
        [_audio copyRangeFrom:_cursor to:now into:&_utterance skipped:&skipped];
        _cursor = now;
    }
}

#pragma mark - idle teardown

- (void)armedIdleAndSchedule {
    [self setState:[_audio isArmed] ? yap::State::Armed : yap::State::Idle];
    [self scheduleIdleTimer];
}

- (void)scheduleIdleTimer {
    [self cancelIdleTimer];
    if (kIdleTimeout <= 0) return;
    _idleTimer = [NSTimer scheduledTimerWithTimeInterval:kIdleTimeout repeats:NO
                                                   block:^(NSTimer * t) {
        if (self->_recording) return;
        YAP_LOG("idle %.0f s — tearing down audio (indicator and sleep assertion clear)",
                kIdleTimeout);
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
    [_audio disarm];
    YAP_LOG("yap terminating");
}

@end
