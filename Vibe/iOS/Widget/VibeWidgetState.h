//
//  VibeWidgetState.h
//  Vibe (iOS)
//
//  What the app publishes and the widget draws. COMPILED INTO BOTH TARGETS, so
//  Foundation only: the extension links no app class. Every field is "what was
//  true at positionDate"; the widget derives the playhead from that instant.
//

#import <Foundation/Foundation.h>

#import "NowPlayingRules.h"     // header-only: the lock screen's tests, which the widget shares

NS_ASSUME_NONNULL_BEGIN

// Both targets' entitlements carry it; a mismatch makes containerURL nil.
extern NSString *const kVibeWidgetAppGroup;

// Posted by loadState to enable publishing, including during gallery previews.
extern const char *const kVibeWidgetReadNotification;

@interface VibeWidgetState : NSObject

// A nil artist means a filename-derived single line (AudioTrack.displayTitle).
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic) BOOL hasTrack;
@property (nonatomic) BOOL playing;
@property (nonatomic) NSTimeInterval duration;

// WidgetPublisher.trackKeyForTrack:, nil with no track. It names the image files, so a publish
// landing between the extension's plist and image reads cannot pair one
// track's title with another's cover; and it rides in every seek button, so a
// tap on a stale render cannot seek what is playing now.
@property (nonatomic, copy, nullable) NSString *trackKey;

// Where the playhead was AT positionDate; the widget advances it itself.
@property (nonatomic) NSTimeInterval position;
@property (nonatomic, copy, nullable) NSDate *positionDate;

// YES: both waveform images are the whole strip as played, and the widget
// draws a line at the playhead. NO: the played image is revealed to it.
@property (nonatomic) BOOL playheadLine;

#pragma mark - Where it lives

// nil when the app group is not provisioned; the widget draws its empty state.
@property (class, nonatomic, readonly, nullable) NSURL *containerURL;

// This snapshot's own images, named by its trackKey; nil with no key.
@property (nonatomic, readonly, nullable) NSURL *artworkURL;
@property (nonatomic, readonly, nullable) NSURL *waveformPlayedURL;
@property (nonatomic, readonly, nullable) NSURL *waveformUnplayedURL;
// Image files belonging to none of trackKeys.
+ (NSArray<NSURL *> *)imageURLsNotForTrackKeys:(NSArray<NSString *> *)trackKeys;

#pragma mark - Reading and writing

// Posts kVibeWidgetReadNotification even when it returns nil. The Swift names
// are pinned: a rename would break the extension, a build the app never runs.
+ (nullable VibeWidgetState *)loadState NS_SWIFT_NAME(load());
- (BOOL)save;

// Clamped to the duration. The playhead and the timeline entries share it.
- (NSTimeInterval)positionAtDate:(NSDate *)date NS_SWIFT_NAME(position(at:));
- (double)progressAtDate:(NSDate *)date NS_SWIFT_NAME(progress(at:));

@end

#pragma mark - When to publish

// A seek detector against the widget's own extrapolation. Looser than the
// lock screen's, since a widget entry spans seconds.
static const NSTimeInterval kVibeWidgetPositionTolerance = 2.0;

// Whether a tick publishes a new snapshot. The published fields are the last
// snapshot's. samePublishedTrack is NO when nothing was published yet. The
// widget extrapolates steady playback. So only a new track, a play or pause,
// a changed duration or line, or a jump past the tolerance publishes. Tags
// landing after the start change the lines, not the identity. While the open
// runs the playhead is pinned at 0, so the position alone publishes nothing.
static inline BOOL VibeWidgetNeedsPublish(BOOL samePublishedTrack,
                                          BOOL publishedHasTrack,
                                          NSString *_Nullable publishedTitle,
                                          NSString *_Nullable publishedArtist,
                                          BOOL publishedPlaying,
                                          NSTimeInterval publishedDuration,
                                          NSTimeInterval publishedPosition,
                                          CFAbsoluteTime publishedAt,
                                          BOOL hasTrack,
                                          NSString *_Nullable title,
                                          NSString *_Nullable artist,
                                          BOOL playing,
                                          NSTimeInterval duration,
                                          NSTimeInterval position,
                                          BOOL startPending,
                                          CFAbsoluteTime now) {
    if (!samePublishedTrack) {
        return YES;
    }
    if (publishedHasTrack != hasTrack || publishedPlaying != playing) {
        return YES;
    }
    if (fabs(publishedDuration - duration) > 0.5) {
        return YES;
    }
    if (!VibeNowPlayingStringsEqual(publishedTitle, title) || !VibeNowPlayingStringsEqual(publishedArtist, artist)) {
        return YES;
    }
    if (startPending) {
        return NO;
    }
    return VibeNowPlayingPositionIsDirty(publishedPosition, publishedAt, 1.0, publishedPlaying, position, now,
                                         kVibeWidgetPositionTolerance);
}

NS_ASSUME_NONNULL_END
