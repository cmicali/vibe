//
//  TrackCommands.h
//  Vibe
//
//  The three commands that act on a list of tracks and nothing else: reveal
//  them, copy the files, copy the names. Each has two call sites that differ
//  only in which tracks they name — the Edit and window-body menus act on the
//  CURRENT track (MainPlayerController), the playlist's row context menu on
//  the CLICKED row or the selection containing it (PlaylistController) — so
//  the commands live here and the two menus supply the tracks. An empty list,
//  or one with nothing to copy, is a no-op: the menus validate, and the
//  bare-key and debug paths do not.
//

#import <Foundation/Foundation.h>

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface TrackCommands : NSObject

+ (void)revealInFinder:(NSArray<AudioTrack *> *)tracks;

// The file URLs themselves go on the pasteboard, so a Finder paste duplicates
// the files rather than pasting their paths as text.
+ (void)copyFiles:(NSArray<AudioTrack *> *)tracks;

// One name per line: a multi-row copy pastes as a list.
+ (void)copyNames:(NSArray<AudioTrack *> *)tracks;

@end

NS_ASSUME_NONNULL_END
