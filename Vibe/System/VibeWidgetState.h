//
//  VibeWidgetState.h
//  Vibe
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

// Posted by noteWidgetDemand — a Darwin notification, so it crosses from the
// extension's process to the app's. The app publishes only while it believes
// a widget is placed (WidgetPublisher), and this is how a widget added while
// the app is in the background gets it publishing again. Under the unit
// tests' container override the name is that directory's own, so a test
// publisher never hears a real widget, nor a real app a test.
FOUNDATION_EXPORT const char *VibeWidgetDemandNotification(void);

// The theme dictionary's keys. Two palettes, one per appearance, each mapping
// a color key to sRGB components [r, g, b, a]; and the transport glyphs, as
// SF Symbol names.
extern NSString *const kVibeWidgetThemeDark;
extern NSString *const kVibeWidgetThemeLight;
extern NSString *const kVibeWidgetThemePlayGlyph;
extern NSString *const kVibeWidgetThemePauseGlyph;
extern NSString *const kVibeWidgetThemeNextGlyph;
extern NSString *const kVibeWidgetColorTitle;
extern NSString *const kVibeWidgetColorArtist;
extern NSString *const kVibeWidgetColorPlayButton;
extern NSString *const kVibeWidgetColorNextButton;
extern NSString *const kVibeWidgetColorBackground;

// Copying is for a republish that changes one field: a snapshot already handed
// to the writing queue is never mutated.
@interface VibeWidgetState : NSObject <NSCopying>

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
// Playing, but the file is still opening: the position is a pinned
// placeholder, and advancing it would show progress through audio that has
// not played. The app publishes again when the open lands.
@property (nonatomic) BOOL startPending;

// The mac theme's choices for what the widget draws, under the kVibeWidgetTheme
// keys; nil on iOS, which has no themes. An absent key is the widget's own
// default. WidgetPublisher's palette decides which colors appear: the window's
// whole look for a side whose surface the theme paints, else only what the
// theme sets.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *theme;

#pragma mark - Where it lives

// nil when the app group is not provisioned — the widget then draws its empty
// state rather than failing.
@property (class, nonatomic, readonly, nullable) NSURL *containerURL;

// This snapshot's own images, named by its trackKey; nil with no key.
@property (nonatomic, readonly, nullable) NSURL *artworkURL;
// The strip, whole in each side's colours. The light pair is baked only while
// the mac theme paints the widget's background light-side, the one case the
// widget is not dark.
- (nullable NSURL *)waveformURLPlayed:(BOOL)played light:(BOOL)light
        NS_SWIFT_NAME(waveformURL(played:light:));
// The theme's no-artwork image for one appearance. Not per track and not
// swept: it changes only with the theme, and absent means the widget's glyph.
+ (nullable NSURL *)placeholderURLForDark:(BOOL)isDark NS_SWIFT_NAME(placeholderURL(forDark:));
// Every image file in the container that belongs to neither key. The writer
// keeps the outgoing track's set through one more publish, so an extension
// that read the previous plist a moment ago still finds the images it names.
+ (NSArray<NSURL *> *)imageURLsNotForTrackKeys:(NSArray<NSString *> *)trackKeys;

#pragma mark - Whether a widget may exist

// The app's WidgetKit-free first answer to "is a widget placed?", so a launch
// with none never loads WidgetKit to ask (VibeWidgetReloader.swift says what
// that costs). noteWidgetDemand marks the container; the app asks WidgetKit
// only while the mark is there, and clears it when the answer is none. A mark
// left by a widget removed while the app was closed costs that one query.
@property (class, nonatomic, readonly) BOOL widgetMayBePlaced;
+ (void)forgetWidget;

// A placed widget is rendering: marks the container and posts
// VibeWidgetDemandNotification. The extension calls it for its timelines and
// non-preview snapshots only. TRAP: never for a gallery preview — WidgetKit
// renders those with nothing placed, and each one turned publishing on.
+ (void)noteWidgetDemand;

#pragma mark - Reading and writing

// nil when nothing has been published yet, or the file is unreadable. Only a
// read: it signals nothing (noteWidgetDemand does). The Swift names are pinned
// rather than left to the importer's own shortening, since the extension is
// the only caller and a rename here would break a build the app target never
// compiles.
+ (nullable VibeWidgetState *)loadState NS_SWIFT_NAME(load());
- (BOOL)save;

// position advanced to `date` when playing, clamped to the duration. The
// widget's playhead and the timeline's entries both come through here, so the
// two cannot disagree about where the head is.
- (NSTimeInterval)positionAtDate:(NSDate *)date NS_SWIFT_NAME(position(at:));
- (double)progressAtDate:(NSDate *)date NS_SWIFT_NAME(progress(at:));

@end

NS_ASSUME_NONNULL_END
