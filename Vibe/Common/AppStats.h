//
//  AppStats.h
//  Vibe
//

#import <Foundation/Foundation.h>

// Lifetime usage counters, persisted in NSUserDefaults. Main thread only:
// every caller — the open sinks and the player delegates — already lives there.
//
// Both platforms count, and both show the totals in Settings > About. What
// differs is only how a running listening clock is kept honest across the
// process going quiet, and that is one #if TARGET_OS_OSX block in the
// implementation: the mac brackets its clock around system sleep and holds off
// sudden termination, iOS folds it at every background and terminate edge.
@interface AppStats : NSObject

+ (AppStats *)sharedInstance;

@property (readonly) NSUInteger totalFilesOpened;
@property (readonly) NSUInteger totalFoldersOpened;
// Wall-clock listening time, including the in-progress run while playing.
@property (readonly) NSTimeInterval totalSecondsPlayed;

// fileCount is the playable files that landed in the playlist, folderCount the
// top-level directories among what the user opened, so a folder open bumps
// both.
- (void)recordOpenedFiles:(NSUInteger)fileCount folders:(NSUInteger)folderCount;

// Playback-time accounting. playbackStarted on an already-running clock folds
// the elapsed run into the persisted total and restarts it — that is the
// periodic flush, landing on every track change — and playbackStopped without
// a running clock is a no-op, so redundant calls are safe.
- (void)playbackStarted;
- (void)playbackStopped;

@end
