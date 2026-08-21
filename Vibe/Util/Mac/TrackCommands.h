//
//  TrackCommands.h
//  Vibe
//
//  The three commands that act on one track and nothing else: reveal it, copy
//  the file, copy the name. Each has two call sites that differ only in which
//  track they name — the Edit and window-body menus act on the CURRENT track
//  (MainPlayerController), the playlist's row context menu on the CLICKED one
//  (PlaylistController) — so the commands live here and the two menus supply
//  the track. A nil track, or one with nothing to copy, is a no-op: the menus
//  validate, and the bare-key and debug paths do not.
//

#import <Foundation/Foundation.h>

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface TrackCommands : NSObject

+ (void)revealInFinder:(nullable AudioTrack *)track;

// The file URL itself goes on the pasteboard, so a Finder paste duplicates the
// file rather than pasting its path as text.
+ (void)copyFile:(nullable AudioTrack *)track;

+ (void)copyName:(nullable AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
