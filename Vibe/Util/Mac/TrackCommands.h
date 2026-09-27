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

// The file URLs, so a Finder paste copies the files.
+ (void)copyFiles:(NSArray<AudioTrack *> *)tracks;

// One name per line.
+ (void)copyNames:(NSArray<AudioTrack *> *)tracks;

@end

NS_ASSUME_NONNULL_END
