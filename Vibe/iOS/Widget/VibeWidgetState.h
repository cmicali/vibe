//
//  VibeWidgetState.h
//  Vibe (iOS)
//
//  What the app publishes and the widget extension draws. COMPILED INTO BOTH
//  TARGETS — the app writes, the extension reads — so it may import nothing
//  but Foundation: the extension links no app class.
//
//  The snapshot is what the widget can know. It is not a live read: WidgetKit
//  renders an archived view out of process, minutes after the app last ran, so
//  every field here is "what was true at positionDate" and the playhead is
//  derived from that instant, never polled.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The one shared container. Both targets carry it in their entitlements; a
// mismatch shows up as containerURL returning nil, never as stale data.
extern NSString *const kVibeWidgetAppGroup;

@interface VibeWidgetState : NSObject

// The two lines the desktop header draws, under the same rule: a nil artist
// means the title is a filename-derived single line (AudioTrack.displayTitle).
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic) BOOL hasTrack;
@property (nonatomic) BOOL playing;
@property (nonatomic) NSTimeInterval duration;

// AudioTrack.cacheKey for the published track, or nil for none. The widget
// never reads it; the app compares it against the last publish to decide
// whether the artwork and waveform files still describe this track, which is
// what keeps a 3 Hz tick from re-encoding a JPEG.
@property (nonatomic, copy, nullable) NSString *trackKey;

// position is where the playhead was AT positionDate. The widget advances it
// itself while playing, which is the only way a WidgetKit view can show motion
// between timeline entries.
@property (nonatomic) NSTimeInterval position;
@property (nonatomic, copy, nullable) NSDate *positionDate;

// Bumped on every publish. The widget keys its image loads on it so a track
// change cannot draw the previous track's artwork against the new title: the
// three files are written before the plist, so a reader that has the plist has
// the images that go with it.
@property (nonatomic) NSInteger generation;

#pragma mark - Where it lives

// nil when the app group is not provisioned — the widget then draws its empty
// state rather than failing.
@property (class, nonatomic, readonly, nullable) NSURL *containerURL;
@property (class, nonatomic, readonly, nullable) NSURL *artworkURL;
@property (class, nonatomic, readonly, nullable) NSURL *waveformPlayedURL;
@property (class, nonatomic, readonly, nullable) NSURL *waveformUnplayedURL;

#pragma mark - Reading and writing

// nil when nothing has been published yet, or the file is unreadable. The
// Swift names are pinned rather than left to the importer's own shortening,
// since the extension is the only caller and a rename here would break a build
// the app target never compiles.
+ (nullable VibeWidgetState *)loadState NS_SWIFT_NAME(load());
- (BOOL)save;

// position advanced to `date` when playing, clamped to the duration. The
// widget's playhead and the timeline's entries both come through here, so the
// two cannot disagree about where the head is.
- (NSTimeInterval)positionAtDate:(NSDate *)date NS_SWIFT_NAME(position(at:));
- (double)progressAtDate:(NSDate *)date NS_SWIFT_NAME(progress(at:));

@end

NS_ASSUME_NONNULL_END
