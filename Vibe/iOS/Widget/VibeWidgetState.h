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

// Posted by loadState — a Darwin notification, so it crosses from the
// extension's process to the app's. A read IS the signal that a widget exists:
// WidgetKit spawns this extension only to render a placed widget or a gallery
// preview, and nothing else ever loads the snapshot. The app publishes only
// while it believes a widget is placed (WidgetPublisher), and this is how a
// widget added while the app is in the background gets it publishing again.
extern const char *const kVibeWidgetReadNotification;

@interface VibeWidgetState : NSObject

// The two lines the desktop header draws, under the same rule: a nil artist
// means the title is a filename-derived single line (AudioTrack.displayTitle).
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic) BOOL hasTrack;
@property (nonatomic) BOOL playing;
@property (nonatomic) NSTimeInterval duration;

// Which track this snapshot describes — an opaque key the app derives from
// the file (NSURL.pathKey), nil when there is no track.
// It does two jobs. It names the image files, so a snapshot can only ever
// pair with its own track's artwork and strip: the extension reads the plist
// and the images as separate reads, and with fixed filenames a publish landing
// between them handed it one track's title over another's cover for a whole
// timeline. And it rides in every seek button, so a tap on a strip that
// WidgetKit has not yet re-rendered cannot seek whatever is playing now.
@property (nonatomic, copy, nullable) NSString *trackKey;

// position is where the playhead was AT positionDate. The widget advances it
// itself while playing, which is the only way a WidgetKit view can show motion
// between timeline entries.
@property (nonatomic) NSTimeInterval position;
@property (nonatomic, copy, nullable) NSDate *positionDate;

#pragma mark - Where it lives

// nil when the app group is not provisioned — the widget then draws its empty
// state rather than failing.
@property (class, nonatomic, readonly, nullable) NSURL *containerURL;

// This snapshot's own images, named by its trackKey; nil with no key.
@property (nonatomic, readonly, nullable) NSURL *artworkURL;
@property (nonatomic, readonly, nullable) NSURL *waveformPlayedURL;
@property (nonatomic, readonly, nullable) NSURL *waveformUnplayedURL;
// Every image file in the container that belongs to neither key. The writer
// keeps the outgoing track's set through one more publish, so an extension
// that read the previous plist a moment ago still finds the images it names.
+ (NSArray<NSURL *> *)imageURLsNotForTrackKeys:(NSArray<NSString *> *)trackKeys;

#pragma mark - Reading and writing

// nil when nothing has been published yet, or the file is unreadable. Posts
// kVibeWidgetReadNotification either way. The Swift names are pinned rather
// than left to the importer's own shortening, since the extension is the only
// caller and a rename here would break a build the app target never compiles.
+ (nullable VibeWidgetState *)loadState NS_SWIFT_NAME(load());
- (BOOL)save;

// position advanced to `date` when playing, clamped to the duration. The
// widget's playhead and the timeline's entries both come through here, so the
// two cannot disagree about where the head is.
- (NSTimeInterval)positionAtDate:(NSDate *)date NS_SWIFT_NAME(position(at:));
- (double)progressAtDate:(NSDate *)date NS_SWIFT_NAME(progress(at:));

@end

NS_ASSUME_NONNULL_END
