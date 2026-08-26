#import "audio.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

#include "log.h"
#include <atomic>
#include <memory>

// Ring holds ~4 s of mono hardware-rate audio. It does not need to hold a whole
// dictation: the worker drains during recording into a growing utterance buffer,
// so the ring only carries slack plus the pre-roll window.
static constexpr double kRingSeconds = 4.0;
static constexpr double kMaxHwRate   = 96000.0;

// Real-time-thread state. POD only, reachable by raw pointer so the tap block
// never retains/releases an ObjC object on the audio thread.
struct TapCtx {
    yap::RingBuffer   ring{(size_t)(kRingSeconds * kMaxHwRate)};
    std::vector<float> scratch;            // preallocated mono downmix target
    std::atomic<bool>  saw_signal{false};
    std::atomic<uint32_t> overlong{0};     // chunks bigger than scratch (should never happen)
};

@implementation YapAudio {
    AVAudioEngine *          _engine;
    std::shared_ptr<TapCtx>  _ctx;
    double                   _hwRate;
    BOOL                     _armed;
    AVAudioConverter *       _conv;        // hw-rate mono -> 16k mono
    double                   _convFromRate;
    id                       _cfgObserver;
    dispatch_queue_t         _q;           // serial queue for rebuilds
    BOOL                     _rebuildPending;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _ctx = std::make_shared<TapCtx>();
    _ctx->scratch.assign(65536, 0.0f);
    _q = dispatch_queue_create("com.samw3.yap.audio", DISPATCH_QUEUE_SERIAL);

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

    __weak YapAudio * weakSelf = self;
    _cfgObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioEngineConfigurationChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification * _) {
        // The engine has already STOPPED itself by now. Must not tear it down
        // from inside this handler: the callback runs on an internal dispatch
        // queue and a synchronous teardown deadlocks.
        [weakSelf scheduleRebuild];
    }];
    return self;
}

- (void)dealloc {
    if (_cfgObserver) [[NSNotificationCenter defaultCenter] removeObserver:_cfgObserver];
}

- (void)scheduleRebuild {
    // Debounce: device transitions arrive in bursts (rate, then channel count,
    // then default device). Rebuilding mid-burst races into format mismatches.
    if (_rebuildPending) return;
    _rebuildPending = YES;
    __weak YapAudio * weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), _q, ^{
        YapAudio * s = weakSelf;
        if (!s) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            s->_rebuildPending = NO;
            if (!s->_armed) return;
            YAP_LOG("audio configuration changed — rebuilding engine");
            [s teardownEngine];
            if (![s arm]) YAP_WARN("rebuild failed; will retry on next arm");
        });
    });
}

- (BOOL)isArmed { return _armed; }
- (double)hardwareRate { return _armed ? _hwRate : 0.0; }
- (uint64_t)framesWritten { return _ctx->ring.written(); }
- (BOOL)hasRealSignal { return _ctx->saw_signal.load(std::memory_order_relaxed); }

- (BOOL)arm {
    if (_armed) return YES;

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

    _hwRate = hw.sampleRate;
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

    _armed = YES;
    YAP_LOG("audio armed: %.0f Hz, %u ch, ring %.1f s",
            _hwRate, (unsigned) nch, kRingSeconds);
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
    AudioUnit au = input.audioUnit;
    if (!au) return;
    OSStatus st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &dev, sizeof(dev));
    if (st != noErr) YAP_INFO("could not pin input device %u (%d)", (unsigned) dev, (int) st);
    else            YAP_INFO("pinned input device %u", (unsigned) dev);
}

- (void)teardownEngine {
    if (!_engine) { _armed = NO; return; }
    @try { [_engine.inputNode removeTapOnBus:0]; } @catch (NSException * _) {}
    if (_engine.isRunning) [_engine stop];
    _engine = nil;
    _armed = NO;
    _conv = nil;
    _convFromRate = 0;
}

- (void)disarm {
    if (!_armed && !_engine) return;
    const uint32_t overlong = _ctx->overlong.load(std::memory_order_relaxed);
    if (overlong) YAP_WARN("%u oversized tap buffers were dropped", overlong);
    [self teardownEngine];
    YAP_LOG("audio disarmed");
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

- (BOOL)resampleTo16k:(const std::vector<float> &)in out:(std::vector<float> *)out {
    if (in.empty()) { out->clear(); return YES; }
    const double from = _hwRate > 0 ? _hwRate : 48000.0;
    if (from == 16000.0) { *out = in; return YES; }

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
