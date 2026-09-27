//
//  AppStats.m
//  Vibe
//

#import "AppStats.h"

#define STAT_FILES_OPENED       @"Stats.filesOpened"
#define STAT_FOLDERS_OPENED     @"Stats.foldersOpened"
#define STAT_SECONDS_PLAYED     @"Stats.secondsPlayed"

@implementation AppStats {
    // systemUptime when the current run began, or 0 while not playing.
    NSTimeInterval _playbackStartUptime;
#if TARGET_OS_OSX
    // A run folded at will-sleep, still active until did-wake restarts it or
    // a stop ends it.
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
        // Never removed: a process-lifetime singleton. Both post on main.
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

// systemUptime is not frozen by sleep on Apple Silicon, and sleep silences the
// engine with no pause callback, so without this bracket a night asleep would
// count as listening.
- (void)workspaceWillSleep:(NSNotification *)notification {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Callback: the Mac is going to sleep");
#endif
    if (_playbackStartUptime <= 0) {
        return;
    }
    [self foldElapsedPlayback];
    _playbackStartUptime = 0;
    _sleepPausedRun = YES;
}

- (void)workspaceDidWake:(NSNotification *)notification {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Callback: the Mac woke");
#endif
    if (_sleepPausedRun) {
        _sleepPausedRun = NO;
        _playbackStartUptime = NSProcessInfo.processInfo.systemUptime;
    }
}

#else

// iOS needs no sleep bracket (anything that silences the session pauses the
// player) but a persistence edge, since a backgrounded app is killed without
// notice. It folds WITHOUT ending the run: playback continues in the
// background.
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
