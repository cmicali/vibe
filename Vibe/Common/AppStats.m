//
// Created by Christopher Micali on 8/10/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "AppStats.h"

#define STAT_FILES_OPENED       @"Stats.filesOpened"
#define STAT_FOLDERS_OPENED     @"Stats.foldersOpened"
#define STAT_SECONDS_PLAYED     @"Stats.secondsPlayed"

@implementation AppStats {
    // systemUptime when the current playback run began, or 0 while not
    // playing. Monotonic, and frozen during system sleep, which is right:
    // sleep silences the engine without a pause callback.
    NSTimeInterval _playbackStartUptime;
}

+ (AppStats *)sharedInstance {
    static AppStats *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AppStats alloc] init];
    });
    return instance;
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
    if (_playbackStartUptime <= 0) {
        // The app supports sudden termination, under which quit is a SIGKILL
        // and applicationWillTerminate: never runs. Holding it off while the
        // clock runs is what lets the quit-time flush actually happen.
        [NSProcessInfo.processInfo disableSuddenTermination];
    }
    [self foldElapsedPlayback];
    _playbackStartUptime = NSProcessInfo.processInfo.systemUptime;
}

- (void)playbackStopped {
    if (_playbackStartUptime <= 0) {
        return;
    }
    [self foldElapsedPlayback];
    _playbackStartUptime = 0;
    [NSProcessInfo.processInfo enableSuddenTermination];
}

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
