//
//  AppStats.m
//  Vibe
//

#import "AppStats.h"

#define STAT_FILES_OPENED       @"Stats.filesOpened"
#define STAT_FOLDERS_OPENED     @"Stats.foldersOpened"
#define STAT_SECONDS_PLAYED     @"Stats.secondsPlayed"

@implementation AppStats {
    // systemUptime when the current playback run began, or 0 while not
    // playing.
    NSTimeInterval _playbackStartUptime;
#if TARGET_OS_OSX
    // A run folded at will-sleep and awaiting its did-wake restart. While set,
    // the run is logically still active — playbackStopped must still balance
    // the sudden-termination hold, and playbackStarted must not re-take it.
    BOOL _sleepPausedRun;
#endif
}

+ (AppStats *)sharedInstance {
    static AppStats *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AppStats alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Process-lifetime singleton, so the observers are never removed. Both
        // platforms' notifications arrive on the main thread, matching this
        // class's main-thread-only contract.
#if TARGET_OS_OSX
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        [center addObserver:self
                   selector:@selector(workspaceWillSleep:)
                       name:NSWorkspaceWillSleepNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(workspaceDidWake:)
                       name:NSWorkspaceDidWakeNotification
                     object:nil];
#else
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self
                   selector:@selector(flushRunningClock:)
                       name:UIApplicationDidEnterBackgroundNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(flushRunningClock:)
                       name:UIApplicationWillTerminateNotification
                     object:nil];
#endif
    }
    return self;
}

- (NSUInteger)totalFilesOpened {
    return (NSUInteger)[[NSUserDefaults standardUserDefaults] integerForKey:STAT_FILES_OPENED];
}

- (NSUInteger)totalFoldersOpened {
    return (NSUInteger)[[NSUserDefaults standardUserDefaults] integerForKey:STAT_FOLDERS_OPENED];
}

- (NSTimeInterval)totalSecondsPlayed {
    NSTimeInterval total = [[NSUserDefaults standardUserDefaults] doubleForKey:STAT_SECONDS_PLAYED];
    if (_playbackStartUptime > 0) {
        total += NSProcessInfo.processInfo.systemUptime - _playbackStartUptime;
    }
    return total;
}

- (void)recordOpenedFiles:(NSUInteger)fileCount folders:(NSUInteger)folderCount {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (fileCount > 0) {
        [defaults setInteger:[defaults integerForKey:STAT_FILES_OPENED] + (NSInteger)fileCount
                      forKey:STAT_FILES_OPENED];
    }
    if (folderCount > 0) {
        [defaults setInteger:[defaults integerForKey:STAT_FOLDERS_OPENED] + (NSInteger)folderCount
                      forKey:STAT_FOLDERS_OPENED];
    }
}

- (void)playbackStarted {
#if TARGET_OS_OSX
    if (![self runActive]) {
        // The app supports sudden termination, under which quit is a SIGKILL
        // and applicationWillTerminate: never runs. Holding it off while the
        // clock runs is what lets the quit-time flush actually happen. iOS has
        // no such API — it folds at every background edge instead, below.
        [NSProcessInfo.processInfo disableSuddenTermination];
    }
#endif
    [self foldElapsedPlayback];
#if TARGET_OS_OSX
    _sleepPausedRun = NO;
#endif
    _playbackStartUptime = NSProcessInfo.processInfo.systemUptime;
}

- (void)playbackStopped {
    if (![self runActive]) {
        return;
    }
    [self foldElapsedPlayback];
    _playbackStartUptime = 0;
#if TARGET_OS_OSX
    _sleepPausedRun = NO;
    [NSProcessInfo.processInfo enableSuddenTermination];
#endif
}

- (BOOL)runActive {
#if TARGET_OS_OSX
    return _playbackStartUptime > 0 || _sleepPausedRun;
#else
    return _playbackStartUptime > 0;
#endif
}

#if TARGET_OS_OSX

// systemUptime is monotonic, but NOT frozen during system sleep on Apple
// Silicon, so sleep — which silences the engine without a pause callback —
// would count the whole night as listening. These two bracket the run instead:
// will-sleep folds and zeroes the baseline, did-wake restarts it.
- (void)workspaceWillSleep:(NSNotification *)notification {
    if (_playbackStartUptime <= 0) {
        return;
    }
    [self foldElapsedPlayback];
    _playbackStartUptime = 0;
    _sleepPausedRun = YES;
}

- (void)workspaceDidWake:(NSNotification *)notification {
    if (_sleepPausedRun) {
        _sleepPausedRun = NO;
        _playbackStartUptime = NSProcessInfo.processInfo.systemUptime;
    }
}

#else

// iOS needs no sleep bracket: a device does not go to sleep out from under a
// running audio session, and anything that does silence one — an interruption,
// a route loss — reaches the player and pauses it, so the run ends through
// playbackStopped like any other. What it needs instead is a persistence edge,
// because a backgrounded app is killed with no notice and no terminate
// callback. Both edges fold the elapsed time into the total and restart the
// baseline WITHOUT ending the run: playback carries on in the background
// (UIBackgroundModes: audio), so the clock must keep running after the write.
- (void)flushRunningClock:(NSNotification *)notification {
    if (_playbackStartUptime <= 0) {
        return;
    }
    [self foldElapsedPlayback];
    _playbackStartUptime = NSProcessInfo.processInfo.systemUptime;
}

#endif

- (void)foldElapsedPlayback {
    if (_playbackStartUptime <= 0) {
        return;
    }
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - _playbackStartUptime;
    if (elapsed > 0) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setDouble:[defaults doubleForKey:STAT_SECONDS_PLAYED] + elapsed
                     forKey:STAT_SECONDS_PLAYED];
    }
}

@end
