//
//  AppStats.h
//  Vibe
//

#import <Foundation/Foundation.h>

// Lifetime usage counters, persisted in NSUserDefaults. Main thread only.
@interface AppStats : NSObject

+ (AppStats *)sharedInstance;

@property (readonly) NSUInteger totalFilesOpened;
@property (readonly) NSUInteger totalFoldersOpened;
// Wall-clock listening time, including the in-progress run while playing.
@property (readonly) NSTimeInterval totalSecondsPlayed;

// fileCount is the playable files that landed in the playlist, folderCount the
// top-level directories the user opened, so a folder open bumps both.
- (void)recordOpenedFiles:(NSUInteger)fileCount folders:(NSUInteger)folderCount;

// playbackStarted on a running clock folds the elapsed run into the total and
// restarts it (the flush on every track change); playbackStopped without a
// running clock is a no-op, so redundant calls are safe.
- (void)playbackStarted;
- (void)playbackStopped;

@end
