#import "audio.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

#include "log.h"
#include <atomic>
#include <memory>
#include <mutex>

// Ring holds ~4 s of mono hardware-rate audio. It does not need to hold a whole
// dictation: the worker drains during recording into a growing utterance buffer,
// so the ring only carries slack plus the pre-roll window.
static constexpr double kRingSeconds = 4.0;
static constexpr double kMaxHwRate   = 96000.0;

// How long -arm will wait on the queue before giving up on this press. Arming
// normally takes ~100 ms; anything past a second means the HAL is not answering.
static constexpr double kArmTimeout      = 2.0;
static constexpr double kRebuildDebounce = 0.150;

// Real-time-thread state. POD only, reachable by raw pointer so the tap block
// never retains/releases an ObjC object on the audio thread.
struct TapCtx {
    yap::RingBuffer   ring{(size_t)(kRingSeconds * kMaxHwRate)};
    std::vector<float> scratch;            // preallocated mono downmix target
    std::atomic<bool>  saw_signal{false};
    std::atomic<uint32_t> overlong{0};     // chunks bigger than scratch (should never happen)
};

// Declared up front so -scheduleRebuild and -arm can reach them regardless of
// definition order, and so the _q-only contract is stated in one place.
@interface YapAudio ()
- (BOOL)armOnQueue;          // _q only
- (void)teardownEngine;      // _q only
- (BOOL)configurationDidChange;  // _q only
@end

@implementation YapAudio {
    // ---- owned by _q; never touched from the main thread ----
    //
    // Every CoreAudio call that can stall lives behind this queue. Building an
    // engine asks the HAL for the hardware format, and that call has no timeout:
    // with an aggregate device mid-flight -- Siri's voice trigger, a conferencing
    // app -- it can grind for minutes and never return. On the main thread that
    // is a frozen menu bar, a dead hotkey and a state machine stuck in Recording.
    // Here it is only a microphone that has not come back yet.
    AVAudioEngine *          _engine;
    id                       _cfgObserver;
    // What the live engine was actually built against, so a configuration-change
    // notification can be checked against reality instead of believed.
    AVAudioChannelCount      _hwChannels;
    AudioDeviceID            _pinnedDevice;

    // ---- published to the main thread ----
    // Atomic so a reader never blocks behind a stalled rebuild.
    std::atomic<bool>        _armed;
    std::atomic<double>      _hwRate;
    std::atomic<uint64_t>    _generation;
    std::atomic<bool>        _rebuildPending;

    // ---- free-threaded ----
    std::shared_ptr<TapCtx>  _ctx;          // RT-safe by construction
    dispatch_queue_t         _q;
    AudioObjectPropertyListenerBlock _defaultInputListener;

    // The converter is a rate-keyed cache with no tie to the engine's lifetime,
    // so it outlives teardown and is guarded on its own rather than by _q.
    std::mutex               _convLock;
    AVAudioConverter *       _conv;         // hw-rate mono -> 16k mono
    double                   _convFromRate;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _ctx = std::make_shared<TapCtx>();
    _ctx->scratch.assign(65536, 0.0f);
    _q = dispatch_queue_create("com.samw3.yap.audio", DISPATCH_QUEUE_SERIAL);
    _armed.store(false, std::memory_order_relaxed);
    _hwRate.store(0.0, std::memory_order_relaxed);
    _generation.store(0, std::memory_order_relaxed);
    _rebuildPending.store(false, std::memory_order_relaxed);
    _convFromRate = 0;

    // "Processes that only ever use the default device are the sort of that
    // should set this property's value to 0" -- AudioHardware.h. Stops the HAL
    // from taking hog mode on our behalf for non-mixable formats.
    UInt32 zero = 0;
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyHogModeIsAllowed,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus st = AudioObjectSetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr,
                                             sizeof(zero), &zero);
    if (st != noErr) YAP_INFO("could not clear HogModeIsAllowed (%d) — harmless", (int) st);

    // The configuration-change observer is scoped to the live engine, so it is
    // registered in -arm rather than here. See -observeConfigurationChangesFor:.
    _pinnedDevice = kAudioObjectUnknown;

    [self observeDefaultInputDevice];
    return self;
}

- (void)dealloc {
    if (_cfgObserver) [[NSNotificationCenter defaultCenter] removeObserver:_cfgObserver];
    if (_defaultInputListener) {
        AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &addr,
                                               _q, _defaultInputListener);
    }
}

// Watch the SYSTEM default input, not just our own engine.
//
// AVAudioEngineConfigurationChangeNotification only fires when something
// disturbs the engine we built. Because -pinInputDevice: binds the AUHAL to one
// device, choosing a different input elsewhere -- plugging in a headset, or
// AirPods connecting -- leaves our device untouched and posts us nothing: the
// engine keeps happily recording the mic the user just switched away from.
//
// The reverse direction was always covered, since a device that disappears stops
// the engine and -configurationDidChange catches that. This is the half that was
// missing, and it matters most with the sleep timeout set to never: with a
// timeout the stale pin is corrected by the next arm, but a mic that never
// sleeps never re-pins, so it would stay on the wrong device indefinitely.
- (void)observeDefaultInputDevice {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    __weak YapAudio * weakSelf = self;
    _defaultInputListener = ^(UInt32 n, const AudioObjectPropertyAddress * a) {
        (void) n; (void) a;
        // Same debounce and same reality check as an engine-side change: this
        // only reports that the default MOVED, and -configurationDidChange is
        // what decides whether it moved away from the device we are pinned to.
        [weakSelf scheduleRebuild];
    };
    OSStatus st = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &addr,
                                                      _q, _defaultInputListener);
    if (st != noErr) {
        YAP_WARN("could not watch the default input device (%d) — a mid-session "
                 "input switch will not be picked up until the next arm", (int) st);
        _defaultInputListener = nil;
    }
}

- (void)observeConfigurationChangesFor:(AVAudioEngine *)engine {
    // Scoped to THIS engine: a torn-down engine keeps posting configuration
    // changes while it finishes stopping, and object:nil would let those rebuild
    // whatever replaced it.
    if (_cfgObserver) [[NSNotificationCenter defaultCenter] removeObserver:_cfgObserver];
    __weak YapAudio * weakSelf = self;
    _cfgObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioEngineConfigurationChangeNotification
                    object:engine
                     queue:nil
                usingBlock:^(NSNotification * _) {
        // The engine has usually STOPPED itself by now. Must not tear it down
        // from inside this handler: the callback runs on an internal dispatch
        // queue and a synchronous teardown deadlocks.
        [weakSelf scheduleRebuild];
    }];
}

// A configuration-change notification is not proof that OUR configuration
// changed: the aggregate device behind the input node churns on its own. Require a
// real difference before paying for a rebuild -- except for an engine that has
// stopped, which must always be rebuilt, because `_armed` over a stopped engine is
// silence that reports itself as working.
- (BOOL)configurationDidChange {
    if (!_engine) return YES;

    if (!_engine.isRunning) {
        YAP_LOG("engine stopped itself — rebuilding");
        return YES;
    }

    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof(dev);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &sz, &dev) == noErr
        && dev != kAudioObjectUnknown && dev != _pinnedDevice) {
        YAP_LOG("default input device %u -> %u — rebuilding",
                (unsigned) _pinnedDevice, (unsigned) dev);
        return YES;
    }

    AVAudioFormat * hw = [_engine.inputNode inputFormatForBus:0];
    if (!hw || hw.sampleRate <= 0 || hw.channelCount == 0) {
        YAP_LOG("input format no longer readable — rebuilding");
        return YES;
    }
    const double built = _hwRate.load(std::memory_order_relaxed);
    if (hw.sampleRate != built || hw.channelCount != _hwChannels) {
        YAP_LOG("input format %.0f Hz/%u ch -> %.0f Hz/%u ch — rebuilding",
                built, (unsigned) _hwChannels, hw.sampleRate, (unsigned) hw.channelCount);
        return YES;
    }

    YAP_LOG("configuration change with device and format unchanged (%.0f Hz, %u ch) "
            "— keeping the engine running", built, (unsigned) _hwChannels);
    return NO;
}

// Callable from anywhere: the default-input listener runs on _q, and the
// configuration-change observer runs on whichever thread AVFAudio posts from.
- (void)scheduleRebuild {
    // Debounce: device transitions arrive in bursts (rate, then channel count,
    // then default device). Rebuilding mid-burst races into format mismatches.
    // exchange() rather than test-then-set: the three callers are on three
    // different threads, and a plain BOOL let two of them through at once.
    if (_rebuildPending.exchange(true, std::memory_order_acq_rel)) return;
    __weak YapAudio * weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRebuildDebounce * NSEC_PER_SEC)), _q, ^{
        YapAudio * s = weakSelf;
        if (!s) return;
        s->_rebuildPending.store(false, std::memory_order_release);
        if (!s->_armed.load(std::memory_order_acquire)) return;
        if (![s configurationDidChange]) return;
        YAP_LOG("audio configuration changed — rebuilding engine");
        [s teardownEngine];
        if (![s armOnQueue]) YAP_WARN("rebuild failed; will retry on next arm");
    });
}

// All lock-free: these are polled from the main thread while a rebuild may be
// stalled inside CoreAudio, and must never wait on it.
- (BOOL)isArmed { return _armed.load(std::memory_order_acquire) ? YES : NO; }
- (double)hardwareRate {
    return _armed.load(std::memory_order_acquire) ? _hwRate.load(std::memory_order_relaxed) : 0.0;
}
- (uint64_t)framesWritten { return _ctx->ring.written(); }
- (BOOL)hasRealSignal { return _ctx->saw_signal.load(std::memory_order_relaxed); }
- (uint64_t)generation { return _generation.load(std::memory_order_relaxed); }

// Main-thread entry point. The work happens on _q; this only waits for it.
- (BOOL)arm {
    if (_armed.load(std::memory_order_acquire)) return YES;

    __block BOOL ok = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_q, ^{
        ok = [self armOnQueue];
        dispatch_semaphore_signal(done);
    });

    // Bounded on purpose. -armOnQueue can stall indefinitely inside the HAL, and
    // when it does the right answer is "not armed for this press" -- not taking
    // the whole app down with it. The block keeps running; if it eventually
    // succeeds the next press finds _armed already true.
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(kArmTimeout * NSEC_PER_SEC))) != 0) {
        YAP_WARN("arm still running after %.1f s — the audio HAL is not answering; "
                 "leaving it to finish in the background", kArmTimeout);
        return NO;
    }
    return ok;
}

- (BOOL)armOnQueue {
    if (_armed.load(std::memory_order_acquire)) return YES;

    // A fresh engine every time. Reusing one after a configuration change makes
    // it report a stale format, which walks straight into the 0 Hz tap crash.
    _engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode * input = _engine.inputNode;   // never touch outputNode/mainMixerNode

    [self pinInputDevice:input];

    AVAudioFormat * hw = [input inputFormatForBus:0];
    // MANDATORY. installTapOnBus with a 0 Hz / 0-channel format raises an
    // Objective-C exception from AVFAudio that kills the process. The input node
    // reports exactly that when no device is ready -- transiently at launch and
    // reliably while Bluetooth negotiates.
    if (!hw || hw.sampleRate <= 0 || hw.channelCount == 0) {
        YAP_WARN("input format not ready (rate=%.0f ch=%u) — not arming",
                 hw ? hw.sampleRate : 0.0, hw ? (unsigned) hw.channelCount : 0);
        _engine = nil;
        return NO;
    }
    if (hw.sampleRate > kMaxHwRate) {
        YAP_WARN("hardware rate %.0f exceeds supported max %.0f", hw.sampleRate, kMaxHwRate);
        _engine = nil;
        return NO;
    }

    _hwRate.store(hw.sampleRate, std::memory_order_relaxed);
    _ctx->ring.reset();
    _ctx->saw_signal.store(false, std::memory_order_relaxed);

    TapCtx * ctx = _ctx.get();   // raw: no ObjC retain traffic on the RT thread
    const AVAudioChannelCount nch = hw.channelCount;

    @try {
        [input installTapOnBus:0
                    bufferSize:4096
                        format:hw
                         block:^(AVAudioPCMBuffer * buf, AVAudioTime * when) {
            // ---- real-time thread: no alloc, no locks, no logging, no ObjC alloc ----
            const AVAudioFrameCount n = buf.frameLength;
            if (n == 0) return;
            const float * const * ch = buf.floatChannelData;
            if (!ch) return;                       // non-float format; nothing safe to do

            if (n > ctx->scratch.size()) {         // must not resize here
                ctx->overlong.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            float * mono = ctx->scratch.data();

            if (nch == 1) {
                std::memcpy(mono, ch[0], n * sizeof(float));
            } else {
                // Hand-rolled downmix on purpose: AVAudioConverter's channel
                // mapping takes only the left channel of stereo and yields pure
                // silence for 4-channel interfaces. Also skip all-zero channels,
                // which multi-input devices expose as unused and which would
                // otherwise just attenuate the result.
                uint32_t used = 0;
                for (AVAudioChannelCount c = 0; c < nch; ++c) {
                    bool nonzero = false;
                    const float * s = ch[c];
                    for (AVAudioFrameCount i = 0; i < n; ++i) { if (s[i] != 0.0f) { nonzero = true; break; } }
                    if (!nonzero) continue;
                    if (used == 0) std::memcpy(mono, s, n * sizeof(float));
                    else for (AVAudioFrameCount i = 0; i < n; ++i) mono[i] += s[i];
                    ++used;
                }
                if (used == 0) std::memset(mono, 0, n * sizeof(float));
                else if (used > 1) {
                    const float inv = 1.0f / (float) used;
                    for (AVAudioFrameCount i = 0; i < n; ++i) mono[i] *= inv;
                }
            }

            if (!ctx->saw_signal.load(std::memory_order_relaxed)) {
                for (AVAudioFrameCount i = 0; i < n; ++i) {
                    if (mono[i] != 0.0f) { ctx->saw_signal.store(true, std::memory_order_relaxed); break; }
                }
            }
            ctx->ring.write(mono, n);
        }];
    } @catch (NSException * e) {
        YAP_FAULT("installTapOnBus threw %{public}s — not arming", e.reason.UTF8String);
        _engine = nil;
        return NO;
    }

    [_engine prepare];
    NSError * err = nil;
    if (![_engine startAndReturnError:&err]) {
        YAP_WARN("engine start failed: %{public}s", err.localizedDescription.UTF8String);
        @try { [input removeTapOnBus:0]; } @catch (NSException * _) {}
        _engine = nil;
        return NO;
    }

    _hwChannels = nch;
    const uint64_t gen = _generation.fetch_add(1, std::memory_order_relaxed) + 1;
    [self observeConfigurationChangesFor:_engine];
    // Published last: _armed is what lets the main thread start reading frames,
    // so everything it will read has to be in place first.
    _armed.store(true, std::memory_order_release);
    YAP_LOG("audio armed: %.0f Hz, %u ch, ring %.1f s (generation %llu)",
            hw.sampleRate, (unsigned) nch, kRingSeconds, (unsigned long long) gen);
    return YES;
}

- (void)pinInputDevice:(AVAudioInputNode *)input {
    // Bind explicitly rather than trusting the engine to follow the default
    // device: AVAudioEngine builds a hidden CADefaultDeviceAggregate at init and
    // that aggregate can go stale on a default-device switch, leaving isRunning
    // == true while buffers complete with silence. Nothing errors.
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof(dev);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &sz, &dev) != noErr
        || dev == kAudioObjectUnknown) {
        YAP_INFO("no default input device to pin");
        return;
    }
    // Remember it even if the pin below fails: what matters later is whether the
    // default input device has changed since we armed.
    _pinnedDevice = dev;

    AudioUnit au = input.audioUnit;
    if (!au) return;

    // Only write if it differs: setting kAudioOutputUnitProperty_CurrentDevice is
    // itself a configuration change, and the AUHAL already starts on the default
    // input device, so a redundant write just provokes a rebuild.
    AudioDeviceID cur = kAudioObjectUnknown;
    UInt32 cursz = sizeof(cur);
    if (AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &cur, &cursz) == noErr && cur == dev) {
        YAP_INFO("input device %u already current — not repinning", (unsigned) dev);
        return;
    }

    OSStatus st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &dev, sizeof(dev));
    if (st != noErr) YAP_INFO("could not pin input device %u (%d)", (unsigned) dev, (int) st);
    else            YAP_LOG("pinned input device %u (was %u)", (unsigned) dev, (unsigned) cur);
}

// _q only. Note it does NOT touch the converter: that is a rate-keyed cache
// which rebuilds itself whenever the rate moves, and dropping it here would mean
// reaching across threads to do it.
- (void)teardownEngine {
    // Unpublish first. A consumer that reads frames from a torn-down engine gets
    // a stale timeline, which is worse than getting nothing.
    _armed.store(false, std::memory_order_release);

    // Observer next: a dying engine keeps posting configuration changes, and
    // acting on one would rebuild whatever replaced it.
    if (_cfgObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_cfgObserver];
        _cfgObserver = nil;
    }
    _pinnedDevice = kAudioObjectUnknown;
    if (!_engine) return;
    @try { [_engine.inputNode removeTapOnBus:0]; } @catch (NSException * _) {}
    if (_engine.isRunning) [_engine stop];
    _engine = nil;
}

- (void)disarm {
    // Unpublish synchronously so the caller's very next -isArmed is correct and
    // the privacy indicator stops tracking us; the teardown itself is CoreAudio
    // work and belongs on _q with everything else that can stall.
    if (!_armed.exchange(false, std::memory_order_acq_rel)) {
        // Not armed, but an engine may still be half-built on _q -- fall through
        // so the teardown runs either way.
    }
    const uint32_t overlong = _ctx->overlong.load(std::memory_order_relaxed);
    if (overlong) YAP_WARN("%u oversized tap buffers were dropped", overlong);
    dispatch_async(_q, ^{
        if (!self->_engine) return;
        [self teardownEngine];
        YAP_LOG("audio disarmed");
    });
}

- (BOOL)copyRangeFrom:(uint64_t)fromFrame to:(uint64_t)toFrame into:(std::vector<float> *)out
              skipped:(BOOL *)skipped {
    yap::ReadResult r = _ctx->ring.read_range(fromFrame, toFrame, *out);
    if (skipped) *skipped = r.skipped ? YES : NO;
    if (!r.valid) {
        YAP_WARN("ring buffer lapped during read — dropped %llu frames",
                 (unsigned long long)(toFrame - fromFrame));
        return NO;
    }
    return YES;
}

- (BOOL)resampleTo16k:(const std::vector<float> &)in
             fromRate:(double)fromRate
                  out:(std::vector<float> *)out {
    if (in.empty()) { out->clear(); return YES; }
    // The rate comes from the caller, not from _hwRate: the utterance must be
    // resampled at the rate it was captured at, and a rebuild on _q can move
    // _hwRate out from under a transcription that is already in flight.
    const double from = fromRate > 0 ? fromRate : 48000.0;
    if (from == 16000.0) { *out = in; return YES; }

    std::lock_guard<std::mutex> guard(_convLock);

    AVAudioFormat * inFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                            sampleRate:from channels:1 interleaved:NO];
    AVAudioFormat * outFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                             sampleRate:16000 channels:1 interleaved:NO];
    if (!inFmt || !outFmt) return NO;

    // Converter is built on the worker, never on the audio thread: AVAudioConverter
    // has been reported crashing with EXC_BAD_ACCESS when driven from a render callback.
    if (!_conv || _convFromRate != from) {
        _conv = [[AVAudioConverter alloc] initFromFormat:inFmt toFormat:outFmt];
        _convFromRate = from;
        if (!_conv) { YAP_WARN("could not build %.0f->16000 converter", from); return NO; }
    }
    [_conv reset];

    AVAudioPCMBuffer * src = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inFmt
                                                          frameCapacity:(AVAudioFrameCount) in.size()];
    if (!src) return NO;
    src.frameLength = (AVAudioFrameCount) in.size();
    std::memcpy(src.floatChannelData[0], in.data(), in.size() * sizeof(float));

    const double ratio = 16000.0 / from;
    // Output length is not exactly in*ratio -- the converter carries a few frames
    // between calls, so leave headroom.
    const AVAudioFrameCount cap = (AVAudioFrameCount) (in.size() * ratio) + 64;
    AVAudioPCMBuffer * dst = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt frameCapacity:cap];
    if (!dst) return NO;

    __block BOOL consumed = NO;
    NSError * err = nil;
    AVAudioConverterOutputStatus st =
        [_conv convertToBuffer:dst error:&err
            withInputFromBlock:^AVAudioBuffer * (AVAudioPacketCount need,
                                                 AVAudioConverterInputStatus * status) {
            // Must report NoDataNow after the first buffer. Returning the same
            // buffer whenever asked duplicates audio every time the converter
            // wants extra frames.
            if (consumed) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
            consumed = YES;
            *status = AVAudioConverterInputStatus_HaveData;
            return src;
        }];

    if (st == AVAudioConverterOutputStatus_Error) {
        YAP_WARN("resample failed: %{public}s", err.localizedDescription.UTF8String);
        return NO;
    }
    out->assign(dst.floatChannelData[0], dst.floatChannelData[0] + dst.frameLength);
    return YES;
}

@end
