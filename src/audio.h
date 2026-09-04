#pragma once
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#include "ringbuffer.h"
#include <cstdint>

// Microphone capture with pre-roll.
//
// The engine runs only while ARMED, and is torn down after an idle timeout so
// the privacy indicator and the coreaudiod PreventUserIdleSleep assertion track
// actual use. Arm/teardown is a constantly-exercised path, not an error path.
//
// Deliberately NOT done here:
//   * voice processing (setVoiceProcessingEnabled:) -- it is the one documented
//     mechanism by which one app breaks other apps' capture, and we are
//     input-only so there is no echo to cancel.
//   * touching outputNode / mainMixerNode -- merely referencing them spins up a
//     hidden aggregate device and can force the AirPods quality drop.
//   * hog mode -- we explicitly opt out of the HAL taking it on our behalf.
@interface YapAudio : NSObject

- (instancetype)init;

// Idempotent, and safe to call from the main thread: the CoreAudio work runs on
// a private queue and this waits only a bounded time for it. Returns NO if the
// engine could not start (no input device yet, microphone permission missing) or
// if the HAL did not answer in time -- in that last case the attempt is still
// running, and a later call may find it armed.
- (BOOL)arm;
- (void)disarm;
- (BOOL)isArmed;

// Hardware sample rate of the live engine, or 0 when not armed.
- (double)hardwareRate;

// Absolute frame count produced so far (at the hardware rate).
- (uint64_t)framesWritten;

// Copy [fromFrame, toFrame) of mono hardware-rate audio. Returns NO if the ring
// could not supply it intact.
- (BOOL)copyRangeFrom:(uint64_t)fromFrame to:(uint64_t)toFrame into:(std::vector<float> *)out
              skipped:(BOOL *)skipped;

// Resample mono audio captured at `fromRate` to the 16 kHz mono float that
// Parakeet requires. Pass the rate the samples were actually captured at, which
// is not necessarily the rate the engine is running at now.
- (BOOL)resampleTo16k:(const std::vector<float> &)in
             fromRate:(double)fromRate
                  out:(std::vector<float> *)out;

// Bumped on every successful arm. The absolute frame timeline restarts at 0 with
// each new engine, so a consumer holding frame indices from an earlier generation
// must re-anchor rather than compare across the boundary.
- (uint64_t)generation;

// True once a non-zero sample has been seen since arming. A live mic always has
// a noise floor; exact zeros mean the link is not actually up yet (Bluetooth mics
// emit digital silence for up to ~1.8 s after start).
- (BOOL)hasRealSignal;

@end
#endif
