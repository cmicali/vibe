//
//  TrackCommands.h
//  Vibe
//
//  Shared by the current-track menus (MainPlayerController) and the
//  playlist's row menu (PlaylistController). An empty list is a no-op, since
//  the bare-key and debug paths do not validate.
//

#import <Foundation/Foundation.h>

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface TrackCommands : NSObject

+ (void)revealInFinder:(NSArray<AudioTrack *> *)tracks;

// The file URLs, so a Finder paste copies the files. A remote placeholder is
// left out (handsOutURL:). Tracks that leave nothing to copy beep.
+ (void)copyFiles:(NSArray<AudioTrack *> *)tracks;

// Whether another app may be given this file, by Copy Files or a drag out of
// the playlist. A remote placeholder may not: its bytes are not there, and no
// other app can read it. The path is tested before any stat.
+ (BOOL)handsOutURL:(nullable NSURL *)url;

// One name per line.
+ (void)copyNames:(NSArray<AudioTrack *> *)tracks;

@end

NS_ASSUME_NONNULL_END
