#pragma once
#ifdef __OBJC__
#import <Foundation/Foundation.h>

// In-app updates from GitHub Releases.
//
// This is the ONLY part of Yap that touches the network, and the only reason the
// app resolves a hostname at all. Dictation stays entirely on-device; if the
// user turns the check off in the menu, nothing here ever opens a socket.
//
// Two things are pinned and neither is optional:
//
//   * where the answer comes from -- https://api.github.com/repos/samw3/yap
//   * who signed what the answer points at -- a Developer ID leaf on our team,
//     chained to Apple, with our bundle identifier. That check, not the URL, is
//     what makes the download safe to run.
//
// Nothing here ever raises an alert on its own. An automatic check that
// interrupts someone mid-sentence is worse than a stale copy of Yap, so the
// background path only ever changes what the menu says.

// Posted on the main thread whenever the phase, progress or message changes.
extern NSString * const YapUpdaterDidChangeNotification;

typedef NS_ENUM(NSInteger, YapUpdatePhase) {
    YapUpdatePhaseIdle,         // nothing to say: never checked, or up to date
    YapUpdatePhaseChecking,
    YapUpdatePhaseAvailable,    // a newer release exists; waiting on the user
    YapUpdatePhaseDownloading,
    YapUpdatePhaseVerifying,
    YapUpdatePhaseInstalling,
    YapUpdatePhaseInstalled,    // swapped in, but the relaunch did not happen
    YapUpdatePhaseFailed,
};

@interface YapUpdater : NSObject

+ (instancetype)shared;

@property (readonly) YapUpdatePhase phase;
@property (readonly) double         progress;          // 0..1 while downloading
@property (readonly, copy) NSString * availableVersion; // nil unless one is
@property (readonly, copy) NSURL    * releasePage;
@property (readonly, copy) NSString * failureReason;

// Honours both the user's preference and the once-a-day interval, so it is cheap
// to call on a timer.
- (void)checkInBackground;

// The user asked, so neither the preference nor the interval applies, and the
// outcome is reported in an alert -- including "you are up to date", which is
// the answer a manual check most often deserves.
- (void)checkNow;

// Download, verify, swap the bundle, relaunch. Only acts in Available or Failed.
- (void)installAvailableUpdate;

// One line for the menu, or nil when there is nothing worth a row.
- (NSString *)menuLine;
// YES when clicking that line should start (or retry) an install.
- (BOOL)menuLineIsActionable;
// YES while a download is in flight and can still be taken back.
- (BOOL)canCancel;
- (void)cancelDownload;

@end
#endif
