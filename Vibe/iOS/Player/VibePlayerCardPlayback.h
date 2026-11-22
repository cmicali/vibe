//
//  VibePlayerCardPlayback.h
//  Vibe (iOS)
//
//  The player as the now-playing card sees it. The card names no model class
//  of the app's. It pages through a queue of items, reads the player's state,
//  sends transport commands and hears events. The app adopts these protocols
//  on its own objects, and the card hands its items back unchanged.
//
//  Main thread only.
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#import "AudioTrackMetadataHolder.h"
#import "MusicalKey.h"
#import "OutputRouteRules.h"
#import "PlayerScreenRules.h"
#import "RepeatMode.h"

@class CodableAudioWaveform;

NS_ASSUME_NONNULL_BEGIN

// One page's item.
@protocol VibePlayerCardItem <AudioTrackMetadataHolder>
// The title, or the single line derived from the filename.
- (NSString *)displayTitle;
// nil means no second line.
- (nullable NSString *)displayArtist;
// 0 until metadata knows it.
- (NSTimeInterval)duration;
// The tempo and key to show. 0 and VibeMusicalKeyNone mean none.
- (float)bpm;
- (VibeMusicalKey)key;
@end

// The rows the pager pages through.
@protocol VibePlayerCardQueue <NSObject>
- (NSUInteger)count;
- (nullable id<VibePlayerCardItem>)trackAtIndex:(NSUInteger)index;
@property (nonatomic, readonly) NSUInteger currentIndex;
- (nullable id<VibePlayerCardItem>)currentTrack;
// -1 when the track is not in the queue.
- (NSInteger)getIndexForTrack:(nullable id<VibePlayerCardItem>)track;
// Whether Next goes anywhere from the current row, under shuffle and repeat.
- (BOOL)hasNextTrack;
@property (nonatomic, readonly) BOOL shuffleEnabled;
@property (nonatomic, readonly) VibeRepeatMode repeatMode;
@end

@protocol VibePlayerCardPlayback;

// The events the card handles. The app's own observer protocol may refine it,
// so one broadcast reaches the card and the app's other screens.
@protocol VibePlayerCardObserver <NSObject>
@optional

#pragma mark Playlist structure

// The whole row set changed and the cursor is final.
- (void)playbackDidReplacePlaylist:(id<VibePlayerCardPlayback>)playback;
- (void)playback:(id<VibePlayerCardPlayback>)playback didAppendTracksAtIndexes:(NSIndexSet *)indexes;
- (void)playback:(id<VibePlayerCardPlayback>)playback
        didChangeCurrentIndexFromIndex:(NSUInteger)previousIndex;

#pragma mark The current track

// The cursor arrived on a track the player is about to run. Preceded by
// playbackDidRenderCurrentTrack:, except on a gapless splice, where it follows.
- (void)playbackDidMoveToCurrentTrack:(id<VibePlayerCardPlayback>)playback animated:(BOOL)animated;

// The current track must be drawn afresh.
- (void)playbackDidRenderCurrentTrack:(id<VibePlayerCardPlayback>)playback;

- (void)playbackDidChangePlayState:(id<VibePlayerCardPlayback>)playback;

// Shuffle or the repeat mode changed, and with them where next goes.
- (void)playbackDidChangePlayOrder:(id<VibePlayerCardPlayback>)playback;

// Up to 3 Hz while playing in an active scene, plus playhead-changing events.
- (void)playbackDidTick:(id<VibePlayerCardPlayback>)playback;

#pragma mark The output route

// Read outputRouteKind and outputRouteName; no payload.
- (void)playbackDidChangeOutputRoute:(id<VibePlayerCardPlayback>)playback;

#pragma mark The current track's open

- (void)playbackDidBeginLoading:(id<VibePlayerCardPlayback>)playback;
// A materializing cloud file's best-effort fill; negative removes it.
- (void)playback:(id<VibePlayerCardPlayback>)playback didUpdateLoadingProgress:(float)fraction;
- (void)playbackDidFinishLoading:(id<VibePlayerCardPlayback>)playback;
- (void)playbackDidFailCurrentTrack:(id<VibePlayerCardPlayback>)playback;

#pragma mark Deliveries

- (void)playback:(id<VibePlayerCardPlayback>)playback didLoadMetadataForTrack:(id<VibePlayerCardItem>)track;

@end

@protocol VibePlayerCardPlayback <NSObject>

// Held weakly and called synchronously.
- (void)addObserver:(id<VibePlayerCardObserver>)observer;

#pragma mark What there is to play

@property (nonatomic, readonly) id<VibePlayerCardQueue> playlist;
@property (nonatomic, readonly, nullable) id<VibePlayerCardItem> currentTrack;
@property (nonatomic, readonly) NSUInteger currentIndex;

#pragma mark Display state

@property (nonatomic, readonly) VibePlayerScreenState screenState;
// Shown on the artist line until the next track event.
@property (nonatomic, readonly, nullable) NSString *errorText;
// The current page shows Buffering….
@property (nonatomic, readonly) BOOL bufferingNoticeShown;
// The current row's open reported a transfer or passed the slow-open
// threshold. Set before playbackDidBeginLoading:, and cleared by every cursor
// change, replacement and play.
@property (nonatomic, readonly) BOOL currentOpenSlow;

#pragma mark The player

@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) NSTimeInterval position;
@property (nonatomic, readonly) NSTimeInterval duration;
// The position reports the pre-seek value until the seek lands, so a waveform
// holds the target meanwhile rather than snapping back.
@property (nonatomic, readonly) BOOL seekInFlight;
@property (nonatomic, readonly) float pendingSeekProgress;
@property (nonatomic, readonly) VibeOutputRouteKind outputRouteKind;
@property (nonatomic, readonly, nullable) NSString *outputRouteName;

#pragma mark Transport

- (void)playPause;
- (void)next;
- (void)previous;
// Ignores an out-of-range index.
- (void)selectTrackAtIndex:(NSUInteger)index;
- (void)seekToProgress:(float)progress;
- (void)toggleShuffle;
- (void)cycleRepeatMode;
// The FX pad's normalized point, x 0..1 left to right and y 0..1 bottom to
// top. engaged NO is the release.
- (void)setFXPadPosition:(CGPoint)position engaged:(BOOL)engaged;

#pragma mark What the card noticed

// The waveform decode detected a tempo for what track sounds. The card hears
// it back as the metadata event when a row's tempo changed.
- (void)noteDetectedBPM:(float)bpm forTrack:(id<VibePlayableItem>)track;
// One track's tags ahead of any sweep. A no-op once the track is parsed.
- (void)loadMetadataNowForTrack:(nullable id<VibePlayerCardItem>)track;
// A page's complete waveform, for a track that may no longer be current.
- (void)noteCompleteWaveform:(CodableAudioWaveform *)waveform forTrack:(id<VibePlayerCardItem>)track;
// A page's full-size art finished decoding, for a track that may no longer be
// current.
- (void)noteLoadedArtForTrack:(id<VibePlayerCardItem>)track;

@end

NS_ASSUME_NONNULL_END
