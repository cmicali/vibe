//
//  VibeWidgetState.h
//  Vibe (iOS)
//
//  What the app publishes and the widget draws. COMPILED INTO BOTH TARGETS, so
//  Foundation only: the extension links no app class. Every field is "what was
//  true at positionDate"; the widget derives the playhead from that instant.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Both targets' entitlements carry it; a mismatch makes containerURL nil.
extern NSString *const kVibeWidgetAppGroup;

// A Darwin notification loadState posts. A read IS the signal that a widget
// exists (WidgetKit spawns the extension only to render one), and it is how a
// widget added in the background turns the app's publishing back on.
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

NS_ASSUME_NONNULL_END
