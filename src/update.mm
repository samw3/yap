#import "update.h"

#import <AppKit/AppKit.h>
#import <Security/Security.h>

#import "appicon.h"

#include "log.h"
#include "settings.h"
#include "version.h"

#include <stdio.h>       // renamex_np
#include <sys/stdio.h>   // RENAME_SWAP
#include <unistd.h>      // getpid

NSString * const YapUpdaterDidChangeNotification = @"YapUpdaterDidChange";

// The single endpoint this app talks to. /releases/latest excludes drafts and
// pre-releases, which is exactly the filter wanted: a draft is a release that is
// still being uploaded, and half a disk image is not an update.
static NSString * const kLatestReleaseURL =
    @"https://api.github.com/repos/samw3/yap/releases/latest";
static NSString * const kReleasesPage = @"https://github.com/samw3/yap/releases";
static NSString * const kBundleID = @"com.samw3.yap";
static NSString * const kTeamID   = @"266VNLKVKQ";
static NSString * const kAppName  = @"Yap.app";

static const double kCheckInterval = 24 * 60 * 60;
static const double kRetryInterval = 60 * 60;   // after a check that did not land

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

static NSError * yap_error(NSString * msg) {
    return [NSError errorWithDomain:@"com.samw3.yap.update" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"Unknown error."}];
}

static NSString * running_version(void) {
    NSString * v = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return v.length ? v : @"0";
}

// Tags are written "v0.4.0"; everything user-facing says "0.4.0".
static NSString * display_version(NSString * tag) {
    return ([tag hasPrefix:@"v"] || [tag hasPrefix:@"V"]) ? [tag substringFromIndex:1] : tag;
}

static NSString * user_agent(void) {
    // GitHub rejects an API request that arrives without one.
    return [NSString stringWithFormat:@"Yap/%@ (macOS; +https://github.com/samw3/yap)",
                                      running_version()];
}

// The install-time signature check is the real gate. This one exists so that a
// release JSON naming some other host cannot spend a gigabyte of someone's
// bandwidth before that gate is reached.
static BOOL is_github_https(NSURL * u) {
    if (!u || ![u.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    NSString * h = u.host.lowercaseString;
    if (!h) return NO;
    for (NSString * d in @[@"github.com", @"githubusercontent.com"]) {
        if ([h isEqualToString:d] || [h hasSuffix:[@"." stringByAppendingString:d]]) return YES;
    }
    return NO;
}

// Where an incoming bundle is assembled: a sibling of the app it will replace,
// because the swap is a rename and a rename cannot cross a filesystem. Hidden,
// so a half-copied bundle never appears in Finder as something to double-click.
static NSURL * staging_url_for(NSURL * app) {
    return [app.URLByDeletingLastPathComponent URLByAppendingPathComponent:
            [@"." stringByAppendingFormat:@"%@.incoming", app.lastPathComponent]];
}

static NSString * sh_quote(NSString * s) {
    return [NSString stringWithFormat:@"'%@'",
            [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

// -1 means "could not tell", which must never be treated as "not enough".
static long long free_bytes(NSURL * dir) {
    NSDictionary * v = [dir resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey]
                                            error:NULL];
    NSNumber * n = v[NSURLVolumeAvailableCapacityForImportantUsageKey];
    return n ? n.longLongValue : -1;
}

static NSString * human_bytes(long long b) {
    return [NSByteCountFormatter stringFromByteCount:b countStyle:NSByteCountFormatterCountStyleFile];
}

// ---------------------------------------------------------------------------
// subprocesses
// ---------------------------------------------------------------------------

// Never call from the main thread: it blocks until the tool exits.
static NSString * run_tool(NSString * launch, NSArray<NSString *> * args,
                           int * statusOut, NSError ** err) {
    NSTask * t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:launch];
    t.arguments = args;
    NSPipe * outPipe = [NSPipe pipe];
    NSPipe * errPipe = [NSPipe pipe];
    t.standardOutput = outPipe;
    t.standardError  = errPipe;

    NSError * e = nil;
    if (![t launchAndReturnError:&e]) { if (err) *err = e; return nil; }

    // Drain both pipes concurrently and only then wait. Waiting first deadlocks
    // the moment a tool writes more than a pipe buffer, and draining them one
    // after the other deadlocks on whichever one is not being read.
    __block NSData * errData = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        errData = [errPipe.fileHandleForReading readDataToEndOfFile];
        dispatch_semaphore_signal(done);
    });
    NSData * outData = [outPipe.fileHandleForReading readDataToEndOfFile];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    [t waitUntilExit];

    if (statusOut) *statusOut = t.terminationStatus;
    if (t.terminationStatus != 0 && err) {
        NSString * msg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        *err = yap_error([NSString stringWithFormat:@"%@ failed (%d): %@",
                          launch.lastPathComponent, t.terminationStatus,
                          msg.length ? [msg stringByTrimmingCharactersInSet:
                                        NSCharacterSet.whitespaceAndNewlineCharacterSet]
                                     : @"no output"]);
    }
    return [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
}

// Returns the mount point. hdiutil verifies the image's own checksum on attach
// unless told not to, so a truncated or corrupted download fails here rather
// than becoming a broken install.
static NSString * attach_dmg(NSURL * dmg, NSError ** err) {
    int st = 0;
    NSString * out = run_tool(@"/usr/bin/hdiutil",
                              @[@"attach", dmg.path, @"-nobrowse", @"-readonly", @"-plist"],
                              &st, err);
    if (!out || st != 0) return nil;

    NSData * d = [out dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary * plist = [NSPropertyListSerialization propertyListWithData:d options:0
                                                                     format:NULL error:NULL];
    for (NSDictionary * ent in plist[@"system-entities"]) {
        NSString * mp = ent[@"mount-point"];
        if ([mp isKindOfClass:NSString.class] && mp.length) return mp;
    }
    if (err) *err = yap_error(@"The disk image attached but nothing was mounted.");
    return nil;
}

static void detach_dmg(NSString * mount) {
    int st = 0;
    run_tool(@"/usr/bin/hdiutil", @[@"detach", mount, @"-quiet"], &st, NULL);
    if (st != 0) {
        // Spotlight is usually still walking the volume. There is nothing on it
        // we still need, so forcing it is right rather than leaving it mounted.
        run_tool(@"/usr/bin/hdiutil", @[@"detach", mount, @"-force", @"-quiet"], &st, NULL);
    }
    if (st != 0) YAP_WARN("could not detach %{public}s — it stays mounted until reboot",
                          mount.UTF8String);
}

// ---------------------------------------------------------------------------
// signature verification -- the part that actually makes this safe
// ---------------------------------------------------------------------------

// `validateResources == NO` checks the signature and the executable's code
// directory but skips re-hashing the sealed resources. On this bundle those are
// 1.1 GB of model weights, so the cheap pass is what decides whether the copy is
// worth doing, and the full pass is what decides whether to swap.
static BOOL verify_bundle(NSURL * app, BOOL validateResources, NSError ** err) {
    SecStaticCodeRef code = NULL;
    OSStatus s = SecStaticCodeCreateWithPath((__bridge CFURLRef) app, kSecCSDefaultFlags, &code);
    if (s != errSecSuccess || !code) {
        if (code) CFRelease(code);
        if (err) *err = yap_error([NSString stringWithFormat:
                                   @"The downloaded app is not signed code (OSStatus %d).", (int) s]);
        return NO;
    }

    // "anchor apple generic" is what gives the leaf OU any meaning: it forces the
    // chain to end at Apple's root, so a team identifier cannot simply be
    // asserted by a certificate anyone can mint. The bundle identifier is pinned
    // alongside it, so a different app signed by this same team is still refused.
    NSString * reqStr = [NSString stringWithFormat:
        @"anchor apple generic and identifier \"%@\" and certificate leaf[subject.OU] = \"%@\"",
        kBundleID, kTeamID];
    SecRequirementRef req = NULL;
    s = SecRequirementCreateWithString((__bridge CFStringRef) reqStr, kSecCSDefaultFlags, &req);
    if (s != errSecSuccess || !req) {
        CFRelease(code);
        if (req) CFRelease(req);
        if (err) *err = yap_error(@"Could not build the code requirement.");
        return NO;
    }

    SecCSFlags flags = kSecCSCheckAllArchitectures | kSecCSStrictValidate;
    flags |= validateResources ? kSecCSCheckNestedCode : kSecCSDoNotValidateResources;

    CFErrorRef cfErr = NULL;
    s = SecStaticCodeCheckValidityWithErrors(code, flags, req, &cfErr);
    const BOOL ok = (s == errSecSuccess);
    if (!ok && err) {
        // errSecCSReqFailed is the one that means "signed, but not by us", and it
        // is the only outcome here a user has any chance of interpreting. Every
        // other status is a broken or unsigned bundle, and the raw text is more
        // useful than a paraphrase.
        if (s == errSecCSReqFailed) {
            *err = yap_error(@"The downloaded app is not signed by Yap's developer. "
                              "It was not installed.");
        } else {
            NSString * detail = cfErr ? [(__bridge NSError *) cfErr localizedDescription] : nil;
            *err = yap_error([NSString stringWithFormat:
                @"The downloaded app's signature is not valid: %@",
                detail.length ? detail : [NSString stringWithFormat:@"OSStatus %d", (int) s]]);
        }
    }
    if (cfErr) CFRelease(cfErr);
    CFRelease(req);
    CFRelease(code);
    return ok;
}

// ---------------------------------------------------------------------------

@interface YapUpdater () <NSURLSessionDownloadDelegate>
@property (readwrite) YapUpdatePhase phase;
@property (readwrite) double         progress;
@property (readwrite, copy) NSString * availableVersion;
@property (readwrite, copy) NSURL    * releasePage;
@property (readwrite, copy) NSString * failureReason;
@end

@implementation YapUpdater {
    NSURL *        _assetURL;      // the .dmg on the latest release
    long long      _assetSize;
    // The bundle this install replaces, decided once when the install starts.
    // Every step downstream reads this rather than NSBundle, so a stage that
    // succeeded and a swap that follows it cannot disagree about the target.
    NSURL *        _target;
    NSURLSession * _dlSession;
    BOOL           _checking;
    BOOL           _cancelled;    // suppresses the cancel error from the delegate
    NSDate *       _lastPost;      // progress-notification throttle
}

+ (instancetype)shared {
    static YapUpdater * u;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        u = [[YapUpdater alloc] init];
        [u sweepStaleDownloads];
    });
    return u;
}

// An install that is killed partway leaves behind a gigabyte in the temp
// directory, a gigabyte beside the app, or both -- and /var/folders is not swept
// often enough for that to go unnoticed. This runs once, when the singleton is
// first built, which is well before any install of ours could be in flight.
- (void)sweepStaleDownloads {
    NSFileManager * fm = NSFileManager.defaultManager;
    NSURL * tmp = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    for (NSURL * u in [fm contentsOfDirectoryAtURL:tmp includingPropertiesForKeys:nil
                                           options:0 error:NULL]) {
        NSString * n = u.lastPathComponent;
        if ([n hasPrefix:@"Yap-update-"] && [n.pathExtension isEqualToString:@"dmg"]) {
            YAP_LOG("removing abandoned download %{public}s", n.UTF8String);
            [fm removeItemAtURL:u error:nil];
        }
    }

    NSURL * orphan = staging_url_for(NSBundle.mainBundle.bundleURL.URLByStandardizingPath);
    if ([fm fileExistsAtPath:orphan.path]) {
        YAP_LOG("removing abandoned staging bundle %{public}s", orphan.path.UTF8String);
        [fm removeItemAtURL:orphan error:nil];
    }
}

// Every property above is written on the main queue and read from the menu on
// the main queue, so there is no lock anywhere in this file. Work that cannot
// run there -- the download callbacks, hdiutil, the copy -- hops back via
// -onMain: before touching anything. The one ivar read off the main queue is
// _target, which is written before the background work is dispatched and not
// touched again until it finishes; the dispatch itself is the ordering.
- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

- (void)notify {
    [NSNotificationCenter.defaultCenter postNotificationName:YapUpdaterDidChangeNotification
                                                      object:self];
}

- (void)moveTo:(YapUpdatePhase)p {
    self.phase = p;
    [self notify];
}

- (void)failWith:(NSString *)reason {
    YAP_WARN("update failed: %{public}s", (reason ?: @"unknown").UTF8String);
    self.failureReason = reason.length ? reason : @"Unknown error.";
    self.progress = 0;
    [self moveTo:YapUpdatePhaseFailed];
}

#pragma mark - checking

- (void)checkInBackground {
    if (!yap::settings::auto_update_check()) return;
    const double now = NSDate.date.timeIntervalSince1970;
    if (now - yap::settings::last_update_check() < kCheckInterval) return;
    [self startCheckAnnouncing:NO];
}

- (void)checkNow { [self startCheckAnnouncing:YES]; }

- (void)startCheckAnnouncing:(BOOL)announce {
    // A menu item that does nothing when clicked is indistinguishable from one
    // that is broken, so a manual check always answers -- including when the
    // answer is "something is already happening".
    if (_checking) {
        if (announce) [self alert:@"Already checking for updates" text:@"" buttons:nil];
        return;
    }
    switch (self.phase) {   // an install already under way outranks a new check
        case YapUpdatePhaseDownloading:
        case YapUpdatePhaseVerifying:
        case YapUpdatePhaseInstalling:
        case YapUpdatePhaseInstalled:
            if (announce) [self alert:@"An update is already being installed"
                                 text:[self menuLine] buttons:nil];
            return;
        default: break;
    }
    _checking = YES;
    // Leave an already-found update on screen rather than flickering back to
    // "Checking…" underneath the user's cursor.
    if (self.phase != YapUpdatePhaseAvailable) [self moveTo:YapUpdatePhaseChecking];

    NSMutableURLRequest * req =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kLatestReleaseURL]];
    req.timeoutInterval = 20;
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [req setValue:user_agent() forHTTPHeaderField:@"User-Agent"];

    // Ephemeral, no cookies, no cache, no credentials: an update check must not
    // become a way to recognise this machine across runs.
    NSURLSessionConfiguration * cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.HTTPShouldSetCookies = NO;
    cfg.HTTPCookieStorage    = nil;
    cfg.URLCache             = nil;
    NSURLSession * s = [NSURLSession sessionWithConfiguration:cfg];

    YAP_INFO("checking for updates (running %{public}s)", running_version().UTF8String);
    [[s dataTaskWithRequest:req completionHandler:^(NSData * data, NSURLResponse * resp, NSError * e) {
        [s finishTasksAndInvalidate];
        [self onMain:^{ [self finishCheck:data response:resp error:e announce:announce]; }];
    }] resume];
}

- (void)finishCheck:(NSData *)data response:(NSURLResponse *)resp
              error:(NSError *)netErr announce:(BOOL)announce {
    _checking = NO;

    const NSInteger http = [resp isKindOfClass:NSHTTPURLResponse.class]
                         ? ((NSHTTPURLResponse *) resp).statusCode : 0;
    NSDictionary * rel = nil;
    NSString * problem = nil;

    if (netErr)                        problem = netErr.localizedDescription;
    else if (http == 403 || http == 429) problem = @"GitHub is rate-limiting this network. Try again later.";
    else if (http != 200)              problem = [NSString stringWithFormat:@"GitHub returned HTTP %ld.", (long) http];
    else {
        rel = [NSJSONSerialization JSONObjectWithData:data ?: NSData.data options:0 error:NULL];
        if (![rel isKindOfClass:NSDictionary.class]) problem = @"GitHub's answer was not readable.";
    }

    // A check that did not land retries within the hour instead of tomorrow: the
    // usual cause is a closed lid or no Wi-Fi at the moment the timer fired.
    const double now = NSDate.date.timeIntervalSince1970;
    yap::settings::set_last_update_check(problem ? now - kCheckInterval + kRetryInterval : now);

    if (problem) {
        YAP_WARN("update check failed: %{public}s", problem.UTF8String);
        if (self.phase == YapUpdatePhaseChecking) [self moveTo:YapUpdatePhaseIdle];
        if (announce) [self alert:@"Could not check for updates" text:problem buttons:nil];
        return;
    }

    NSString * tag = [rel[@"tag_name"] isKindOfClass:NSString.class] ? rel[@"tag_name"] : nil;
    if (!tag.length) {
        if (self.phase == YapUpdatePhaseChecking) [self moveTo:YapUpdatePhaseIdle];
        if (announce) [self alert:@"Could not check for updates"
                             text:@"The latest release has no tag." buttons:nil];
        return;
    }

    NSString * running = running_version();
    if (yap::version_compare(tag.UTF8String, running.UTF8String) <= 0) {
        YAP_LOG("up to date: running %{public}s, latest release %{public}s",
                running.UTF8String, tag.UTF8String);
        self.availableVersion = nil;
        self.failureReason    = nil;
        _assetURL = nil;
        [self moveTo:YapUpdatePhaseIdle];
        if (announce) [self alert:[NSString stringWithFormat:@"Yap %@ is the latest version.", running]
                             text:@"" buttons:nil];
        return;
    }

    NSURL * page = [rel[@"html_url"] isKindOfClass:NSString.class]
                 ? [NSURL URLWithString:rel[@"html_url"]] : nil;
    NSURL * asset = nil;
    long long size = 0;
    if ([rel[@"assets"] isKindOfClass:NSArray.class]) {
        for (NSDictionary * a in rel[@"assets"]) {
            if (![a isKindOfClass:NSDictionary.class]) continue;
            NSString * name = a[@"name"];
            if (![name isKindOfClass:NSString.class]) continue;
            if (![name.pathExtension.lowercaseString isEqualToString:@"dmg"]) continue;
            NSString * dl = a[@"browser_download_url"];
            NSURL * u = [dl isKindOfClass:NSString.class] ? [NSURL URLWithString:dl] : nil;
            if (!is_github_https(u)) {
                YAP_WARN("ignoring release asset %{public}s: not served from GitHub over TLS",
                         name.UTF8String);
                continue;
            }
            asset = u;
            size  = [a[@"size"] longLongValue];
            break;
        }
    }

    self.availableVersion = display_version(tag);
    self.releasePage      = page ?: [NSURL URLWithString:kReleasesPage];
    self.failureReason    = nil;
    _assetURL  = asset;
    _assetSize = size;
    [self moveTo:YapUpdatePhaseAvailable];

    if (asset) {
        YAP_LOG("update available: %{public}s -> %{public}s (%{public}s)",
                running.UTF8String, self.availableVersion.UTF8String, human_bytes(size).UTF8String);
    } else {
        // A published release whose disk image has not finished uploading is a
        // real state, not a bug. Say what is there and point at the page.
        YAP_LOG("release %{public}s exists but carries no disk image", tag.UTF8String);
    }
    if (announce) [self announceAvailable];
}

- (void)announceAvailable {
    NSString * body = [NSString stringWithFormat:@"You are running %@.", running_version()];
    if (!_assetURL) {
        body = [body stringByAppendingString:
                @"\n\nThis release does not have a disk image attached yet."];
        if ([self alert:[NSString stringWithFormat:@"Yap %@ is available", self.availableVersion]
                   text:body buttons:@[@"Release Notes", @"Later"]] == NSAlertFirstButtonReturn) {
            [self openReleasePage];
        }
        return;
    }
    body = [body stringByAppendingFormat:@"\n\nThe download is %@.", human_bytes(_assetSize)];
    switch ([self alert:[NSString stringWithFormat:@"Yap %@ is available", self.availableVersion]
                   text:body buttons:@[@"Install Now", @"Release Notes", @"Later"]]) {
        case NSAlertFirstButtonReturn:  [self installAvailableUpdate]; break;
        case NSAlertSecondButtonReturn: [self openReleasePage];        break;
        default: break;
    }
}

- (void)openReleasePage {
    if (self.releasePage) [NSWorkspace.sharedWorkspace openURL:self.releasePage];
}

- (NSModalResponse)alert:(NSString *)title text:(NSString *)text buttons:(NSArray<NSString *> *)buttons {
    NSAlert * a = [[NSAlert alloc] init];
    a.messageText = title;
    a.informativeText = text ?: @"";
    NSImage * icon = yap_app_icon();
    if (icon) a.icon = icon;
    for (NSString * b in (buttons.count ? buttons : @[@"OK"])) [a addButtonWithTitle:b];
    [NSApp activateIgnoringOtherApps:YES];
    return [a runModal];
}

#pragma mark - installing

- (void)installAvailableUpdate {
    switch (self.phase) {
        case YapUpdatePhaseDownloading:
        case YapUpdatePhaseVerifying:
        case YapUpdatePhaseInstalling:
        case YapUpdatePhaseInstalled:
            return;
        default: break;
    }
    if (!_assetURL || !self.availableVersion.length) return;

    NSError * err = nil;
    if (![self resolveTarget:&err]) { [self failWith:err.localizedDescription]; return; }

    self.progress = 0;
    _lastPost = nil;
    _cancelled = NO;
    [self moveTo:YapUpdatePhaseDownloading];
    YAP_LOG("downloading %{public}s", _assetURL.absoluteString.UTF8String);

    NSURLSessionConfiguration * cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForResource = 6 * 60 * 60;   // a gigabyte over a slow link
    cfg.HTTPShouldSetCookies = NO;
    _dlSession = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];

    NSMutableURLRequest * req = [NSMutableURLRequest requestWithURL:_assetURL];
    [req setValue:user_agent() forHTTPHeaderField:@"User-Agent"];
    [[_dlSession downloadTaskWithRequest:req] resume];
}

// Only the download is interruptible, and that is the only phase long enough to
// need it: a gigabyte takes minutes, and someone on a metered connection has to
// be able to take it back. Everything after it is seconds and must not be torn
// apart halfway.
- (BOOL)canCancel { return self.phase == YapUpdatePhaseDownloading; }

- (void)cancelDownload {
    if (![self canCancel]) return;
    YAP_LOG("download cancelled at %.0f%%", self.progress * 100);
    // Invalidating cancels the in-flight task, and the delegate's completion
    // callback lands with NSURLErrorCancelled -- which -failWith: would report
    // as a failure, so the phase is put back first and that callback ignored.
    _cancelled = YES;
    [_dlSession invalidateAndCancel];
    _dlSession = nil;
    self.progress = 0;
    self.failureReason = nil;
    [self moveTo:YapUpdatePhaseAvailable];
}

// Works out what is being replaced and whether replacing it can work at all.
// Everything here fails better before the download than after it.
- (BOOL)resolveTarget:(NSError **)err {
    NSBundle * b = NSBundle.mainBundle;
    NSURL * app = b.bundleURL.URLByStandardizingPath;
    if (![app.pathExtension isEqualToString:@"app"] ||
        ![b.bundleIdentifier isEqualToString:kBundleID]) {
        *err = yap_error(@"Yap is not running from an installed app bundle, so it cannot "
                          "replace itself. Download the update from the release page.");
        return NO;
    }

    NSFileManager * fm = NSFileManager.defaultManager;
    NSURL * parent = app.URLByDeletingLastPathComponent;
    if (![fm isWritableFileAtPath:parent.path] || ![fm isWritableFileAtPath:app.path]) {
        *err = yap_error([NSString stringWithFormat:
            @"%@ is not writable by you, so the update cannot be installed in place. "
             "Download it from the release page instead.", parent.path]);
        return NO;
    }

    // The image and the bundle copied out of it are on the volume at the same
    // time, plus room for the old bundle until the relaunch removes it.
    const long long need = _assetSize > 0 ? _assetSize * 5 / 2 : 0;
    const long long have = free_bytes(parent);
    if (need > 0 && have >= 0 && have < need) {
        *err = yap_error([NSString stringWithFormat:
            @"Installing this update needs about %@ free on %@, and there is %@.",
            human_bytes(need), parent.path, human_bytes(have)]);
        return NO;
    }
    _target = app;
    return YES;
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)task
      didWriteData:(int64_t)wrote
 totalBytesWritten:(int64_t)total
totalBytesExpectedToWrite:(int64_t)expected {
    if (expected <= 0) return;
    const double p = (double) total / (double) expected;
    [self onMain:^{
        if (self.phase != YapUpdatePhaseDownloading) return;
        // Throttled: this fires hundreds of times a second on a fast link and
        // every post re-titles a menu row.
        if (p < 1.0 && self->_lastPost &&
            [NSDate.date timeIntervalSinceDate:self->_lastPost] < 0.5) return;
        self->_lastPost = NSDate.date;
        self.progress = p;
        [self notify];
    }];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)task
didFinishDownloadingToURL:(NSURL *)location {
    // Runs on the session's queue, and `location` is deleted the instant this
    // returns -- so the move happens here, synchronously, before anything else.
    NSFileManager * fm = NSFileManager.defaultManager;
    NSURL * dest = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
                    URLByAppendingPathComponent:
                        [NSString stringWithFormat:@"Yap-update-%08x.dmg", arc4random()]];
    NSError * moveErr = nil;
    const BOOL moved = [fm moveItemAtURL:location toURL:dest error:&moveErr];

    NSHTTPURLResponse * resp = (NSHTTPURLResponse *) task.response;
    const NSInteger http = [resp isKindOfClass:NSHTTPURLResponse.class] ? resp.statusCode : 0;

    [self onMain:^{
        if (http != 200) {
            // A 404 page downloads every bit as successfully as a disk image.
            [fm removeItemAtURL:dest error:nil];
            [self failWith:[NSString stringWithFormat:@"The download returned HTTP %ld.", (long) http]];
            return;
        }
        if (!moved) { [self failWith:moveErr.localizedDescription]; return; }
        [self verifyAndInstall:dest];
    }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    [session finishTasksAndInvalidate];
    if (!error) return;   // the success path is handled above
    [self onMain:^{
        if (self->_cancelled) { self->_cancelled = NO; return; }   // asked for, not a failure
        [self failWith:error.localizedDescription];
    }];
}

#pragma mark - verify, stage, swap

- (void)verifyAndInstall:(NSURL *)dmg {
    [self moveTo:YapUpdatePhaseVerifying];
    NSString * expected = self.availableVersion;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError * err = nil;
        NSString * staged = [self stageFromImage:dmg expecting:expected error:&err];
        [NSFileManager.defaultManager removeItemAtURL:dmg error:nil];
        [self onMain:^{
            if (!staged) [self failWith:err.localizedDescription];
            else         [self swapInStaged:staged];
        }];
    });
}

// Off the main thread. Returns the staged bundle's path, or nil with err set.
- (NSString *)stageFromImage:(NSURL *)dmg expecting:(NSString *)expected error:(NSError **)err {
    NSString * mount = attach_dmg(dmg, err);
    if (!mount) return nil;

    NSString * staged = nil;
    NSURL * mounted = [NSURL fileURLWithPath:[mount stringByAppendingPathComponent:kAppName]];

    if (![NSFileManager.defaultManager fileExistsAtPath:mounted.path]) {
        *err = yap_error([NSString stringWithFormat:
                          @"The downloaded disk image does not contain %@.", kAppName]);
    } else if (verify_bundle(mounted, NO, err) && [self versionOf:mounted matches:expected error:err]) {
        [self onMain:^{ [self moveTo:YapUpdatePhaseInstalling]; }];
        staged = [self copyToStaging:mounted error:err];
    }

    detach_dmg(mount);
    return staged;
}

// Two separate questions, and both are asked here rather than only at check time
// because this is the last moment before the running app is replaced. "Is it
// what the release claimed" catches a tag and a disk image that disagree; "is it
// newer than what is running" is the downgrade guard.
- (BOOL)versionOf:(NSURL *)app matches:(NSString *)expected error:(NSError **)err {
    NSDictionary * info = [NSDictionary dictionaryWithContentsOfURL:
                           [app URLByAppendingPathComponent:@"Contents/Info.plist"] error:NULL];
    NSString * got = info[@"CFBundleShortVersionString"];
    if (![got isKindOfClass:NSString.class] || !got.length) {
        *err = yap_error(@"The downloaded app has no version in its Info.plist.");
        return NO;
    }
    if (yap::version_compare(got.UTF8String, expected.UTF8String) != 0) {
        *err = yap_error([NSString stringWithFormat:
            @"The release is tagged %@ but the disk image contains %@.", expected, got]);
        return NO;
    }
    if (yap::version_compare(got.UTF8String, running_version().UTF8String) <= 0) {
        *err = yap_error([NSString stringWithFormat:
            @"The download is version %@, which is not newer than the running %@.",
            got, running_version()]);
        return NO;
    }
    return YES;
}

- (NSString *)copyToStaging:(NSURL *)mounted error:(NSError **)err {
    NSURL * staging = staging_url_for(_target);
    NSFileManager * fm = NSFileManager.defaultManager;
    [fm removeItemAtURL:staging error:nil];
    if (![fm copyItemAtURL:mounted toURL:staging error:err]) return nil;

    // Nothing here comes through LaunchServices, so nothing should be quarantined
    // -- but a quarantined bundle would meet the user as a Gatekeeper prompt on
    // relaunch, and clearing an attribute that is not there costs nothing.
    run_tool(@"/usr/bin/xattr", @[@"-dr", @"com.apple.quarantine", staging.path], NULL, NULL);

    // The full check, resource seal included, on the exact bytes that are about
    // to become the running app.
    if (!verify_bundle(staging, YES, err)) {
        [fm removeItemAtURL:staging error:nil];
        return nil;
    }
    return staging.path;
}

- (void)swapInStaged:(NSString *)staged {
    NSURL * app = _target;
    NSFileManager * fm = NSFileManager.defaultManager;

    // RENAME_SWAP exchanges the two directories in a single atomic step, which
    // leaves the OLD bundle parked at the staging path. That is the point: this
    // process has the models under Resources mmap'd, and handing the delete to
    // the relaunch script means nothing is unlinked under a running app at all.
    NSString * parked = staged;
    BOOL ok = renamex_np(app.path.fileSystemRepresentation,
                         staged.fileSystemRepresentation, RENAME_SWAP) == 0;
    if (!ok) {
        // Portable fallback for a volume with no atomic swap. Here the old bundle
        // is removed by the OS rather than parked for the script.
        NSError * e = nil;
        ok = [fm replaceItemAtURL:app withItemAtURL:[NSURL fileURLWithPath:staged]
                   backupItemName:nil options:0 resultingItemURL:NULL error:&e];
        parked = nil;
        if (!ok) {
            [fm removeItemAtURL:[NSURL fileURLWithPath:staged] error:nil];
            [self failWith:[NSString stringWithFormat:@"Could not replace %@: %@",
                            app.path, e.localizedDescription ?: @"the rename was refused"]];
            return;
        }
    }

    YAP_LOG("installed %{public}s at %{public}s",
            self.availableVersion.UTF8String, app.path.UTF8String);
    [self moveTo:YapUpdatePhaseInstalled];
    [self relaunch:app.path removing:parked];
}

- (void)relaunch:(NSString *)appPath removing:(NSString *)parked {
    NSMutableString * script = [NSMutableString string];
    // Bounded at 30 s: a pid can be recycled, and an unbounded waiter would then
    // sit on a stranger's process and never relaunch anything.
    [script appendFormat:@"n=0; while /bin/kill -0 %d 2>/dev/null && [ $n -lt 300 ]; do "
                          "/bin/sleep 0.1; n=$((n+1)); done; ", (int) getpid()];
    if (parked.length) [script appendFormat:@"/bin/rm -rf %@; ", sh_quote(parked)];
    [script appendFormat:@"exec /usr/bin/open %@", sh_quote(appPath)];

    NSTask * t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    t.arguments = @[@"-c", script];

    NSError * e = nil;
    if (![t launchAndReturnError:&e]) {
        // The update is already installed at this point. The running process is
        // the old code, still mapped and still working, so say what happened
        // rather than pretending the update failed.
        YAP_WARN("relaunch helper would not start: %{public}s", e.localizedDescription.UTF8String);
        self.failureReason = @"Update installed. Quit and reopen Yap to run it.";
        [self notify];
        return;
    }
    YAP_LOG("relaunching into the updated bundle");
    [NSApp terminate:nil];
}

#pragma mark - menu

- (NSString *)menuLine {
    NSString * v = self.availableVersion;
    switch (self.phase) {
        case YapUpdatePhaseIdle:      return nil;
        case YapUpdatePhaseChecking:  return @"Checking for updates…";
        case YapUpdatePhaseAvailable:
            return _assetURL ? [NSString stringWithFormat:@"Update to %@ — install now", v]
                             : [NSString stringWithFormat:@"Yap %@ is available on GitHub", v];
        case YapUpdatePhaseDownloading:
            return [NSString stringWithFormat:@"Downloading %@ — %.0f%%", v, self.progress * 100];
        case YapUpdatePhaseVerifying:
            return [NSString stringWithFormat:@"Verifying %@…", v];
        case YapUpdatePhaseInstalling:
            return [NSString stringWithFormat:@"Installing %@ — Yap will restart", v];
        case YapUpdatePhaseInstalled:
            return self.failureReason ?: @"Update installed — restarting…";
        case YapUpdatePhaseFailed:
            return v.length ? [NSString stringWithFormat:@"Update to %@ failed — retry", v]
                            : @"Update check failed";
    }
    return nil;
}

- (BOOL)menuLineIsActionable {
    return (self.phase == YapUpdatePhaseAvailable || self.phase == YapUpdatePhaseFailed)
        && _assetURL != nil;
}

@end
