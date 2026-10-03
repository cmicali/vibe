//
//  PlaybackController.h
//  Vibe (iOS)
//
//  Everything the iOS app plays and nothing that draws it; the model half of
//  the mac's MainPlayerController.
//
//  It broadcasts, where the rest of the app uses one weak delegate: three
//  views describe one playback and Playlist has one observer slot. Observers
//  are held weakly and called synchronously, in registration order.
//
//  Main thread only.
//

#import <UIKit/UIKit.h>

#import "EqualizerLevelSource.h"
#import "OutputRouteRules.h"
#import "PlayerScreenRules.h"

@class AudioTrack;
@class PlaybackController;
@class Playlist;

NS_ASSUME_NONNULL_BEGIN

@protocol PlaybackObserver <NSObject>
@optional

#pragma mark Playlist structure

// The whole row set changed and the cursor is final.
- (void)playbackDidReplacePlaylist:(PlaybackController *)playback;
- (void)playback:(PlaybackController *)playback didAppendTracksAtIndexes:(NSIndexSet *)indexes;
// Every Add ends here, after any append it made: landed is NO when it found
// nothing, or nothing new. The playlist's own events say what changed; this
// says the request is over.
- (void)playback:(PlaybackController *)playback didSettleAddLanding:(BOOL)landed;
- (void)playback:(PlaybackController *)playback didReplaceTrackAtIndex:(NSUInteger)index;
- (void)playback:(PlaybackController *)playback
        didChangeCurrentIndexFromIndex:(NSUInteger)previousIndex;

#pragma mark The current track

// The cursor arrived on a track the player is about to run. Preceded by
// playbackDidRenderCurrentTrack:, except on a gapless splice, where it follows.
- (void)playbackDidMoveToCurrentTrack:(PlaybackController *)playback animated:(BOOL)animated;

// The current track must be drawn afresh.
- (void)playbackDidRenderCurrentTrack:(PlaybackController *)playback;

- (void)playbackDidChangePlayState:(PlaybackController *)playback;

// Shuffle or the repeat mode changed, and with them where next goes.
- (void)playbackDidChangePlayOrder:(PlaybackController *)playback;

// 3 Hz while playing, and once for every event that moves the playhead.
- (void)playbackDidTick:(PlaybackController *)playback;

#pragma mark The output route

// Read outputRouteKind and outputRouteName; no payload.
- (void)playbackDidChangeOutputRoute:(PlaybackController *)playback;

#pragma mark The current track's open

- (void)playbackDidBeginLoading:(PlaybackController *)playback;
// A materializing cloud file's best-effort fill; negative removes it.
- (void)playback:(PlaybackController *)playback didUpdateLoadingProgress:(float)fraction;
- (void)playbackDidFinishLoading:(PlaybackController *)playback;
- (void)playbackDidFailCurrentTrack:(PlaybackController *)playback;

#pragma mark Deliveries and the folder session

- (void)playback:(PlaybackController *)playback didLoadMetadataForTrack:(AudioTrack *)track;
// A deliberate open landed and is playing; never sent for a relaunch restore.
// The only event that presents the card.
- (void)playbackDidOpenNewFolder:(PlaybackController *)playback;
// The picked location held no audio files. The playlist stands if it had
// one — read playlist.count before presenting an empty state — and every
// Add in flight was superseded.
- (void)playbackDidOpenEmptyFolder:(PlaybackController *)playback;
// Sent after an open or Add of a CUE sheet settled empty because the sheet's
// folder is denied; openSheetURL:inGrantedFolder:appending: takes the folder.
- (void)playback:(PlaybackController *)playback
        needsFolderOfSheetAtURL:(NSURL *)sheetURL
                      appending:(BOOL)appending;
// A relaunch restore came to nothing, or there was nothing to restore.
- (void)playbackHasNothingToRestore:(PlaybackController *)playback;

@end

// The EqualizerLevelSource too: it alone holds the player.
@interface PlaybackController : NSObject <EqualizerLevelSource>

#pragma mark - Observers

- (void)addObserver:(id<PlaybackObserver>)observer;
- (void)removeObserver:(id<PlaybackObserver>)observer;

#pragma mark - What there is to play

@property (nonatomic, readonly) Playlist *playlist;
@property (nonatomic, readonly, nullable) AudioTrack *currentTrack;
@property (nonatomic, readonly) NSUInteger currentIndex;
// The open folder's display name, nil before anything was opened.
@property (nonatomic, readonly, nullable) NSString *folderDisplayName;

#pragma mark - Display state

// Every screen reads this rather than re-deriving it.
@property (nonatomic, readonly) VibePlayerScreenState screenState;
// The track the screens are describing — nil in the empty and error states.
@property (nonatomic, readonly, nullable) AudioTrack *displayedTrack;
// Shown on the artist line until the next track event.
@property (nonatomic, readonly, nullable) NSString *errorText;

#pragma mark - The player, non-blocking reads

// Set by the scene delegate. Foreground-inactive is NO: Control Center and the
// app switcher leave views attached though nothing of them is visible.
@property (nonatomic, getter=isSceneActive) BOOL sceneActive;

// Modeled output: a playing source or a tracked outgoing fade. Unlike
// isPlaying, NO while a requested track is Loading.
@property (nonatomic, readonly) BOOL audioOutputActive;

@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) NSTimeInterval position;
@property (nonatomic, readonly) NSTimeInterval duration;

// Position reports the pre-seek value until didFinishSeeking:; a waveform
// holds the target meanwhile rather than snapping back.
@property (nonatomic, readonly) BOOL seekInFlight;
@property (nonatomic, readonly) float pendingSeekProgress;

// None before the first activation: nothing has claimed the output yet.
@property (nonatomic, readonly) VibeOutputRouteKind outputRouteKind;
@property (nonatomic, readonly, nullable) NSString *outputRouteName;

#pragma mark - Transport

// Every surface — screens, lock screen, widget, debug channel — comes through
// these.
- (void)playCurrentTrack;
- (void)playPause;
- (void)next;
- (void)previous;
// Ignores an out-of-range index: a list's rows can be stale.
- (void)selectTrackAtIndex:(NSUInteger)index;
- (void)seekToProgress:(float)progress;
- (void)seekToPosition:(NSTimeInterval)position;

#pragma mark - Settings

// A Track transitions writer calls this (the store applies no effects): it
// pushes the crossfade, shuffle and the repeat mode, and re-parks or drops the
// successor, so a mid-track switch to Pause, or to another order, does not
// advance through an armed splice.
- (void)applyTrackTransitionSettings;

// The card's buttons and the system's remote commands: each writes its
// setting and applies.
- (void)toggleShuffle;
- (void)cycleRepeatMode;

// Settings > Playback > Enable audio effects was written: the player connects
// or disconnects the FX segment with the output stopped and puts a playing
// track back; off also releases the pad. The card hides its pad from the
// display notification the same write posts.
- (void)applyFXSetting;

#pragma mark - Effects and tempo

// The one funnel every surface drives the effects through — the card's pad,
// the debug channel. `position` is the pad's normalized point, x 0..1 left to
// right and y 0..1 bottom to top; `engaged` NO is the release. The mapping is
// AudioFXMath.h's: y the low kill's cutoff, x the reverb's level and, past
// the onset, the 1/8-note delay's.
- (void)setFXPadPosition:(CGPoint)position engaged:(BOOL)engaged;

// The decode pass detected a tempo for `track`: stamped on every row sounding
// it (Playlist.stampTracksSounding:usingBlock:), each redrawn, the delay taps
// refed. The match closes the race with a track change.
- (void)noteDetectedBPM:(float)bpm forTrack:(AudioTrack *)track;

// The priority metadata lane, for one track's tags ahead of the sweep. A
// no-op once the track is parsed.
- (void)loadMetadataNowForTrack:(nullable AudioTrack *)track;

#pragma mark - Opening

// "Open in Vibe" from Files or the share sheet.
- (void)handleOpenURLContexts:(NSSet<UIOpenURLContext *> *)contexts;

// A waiter: runs the block once, on main, when the launch's one open has
// settled (restored, nothing to restore, or a cold "Open in Vibe" landed), at
// once if it has. The widget's intents wait on it: before the restore lands
// the playlist is empty and an action does nothing.
- (void)performWhenLaunchOpenSettled:(void (^)(void))block
        NS_SWIFT_NAME(performWhenLaunchOpenSettled(_:));

// URLs from outside the picker, in pick order. openInPlace mirrors
// UIOpenURLContext.options: YES means the real files, so their scopes and the
// expand-to-directory apply.
- (void)openURLs:(NSArray<NSURL *> *)urls openInPlace:(BOOL)openInPlace;

// The sheet playback:needsFolderOfSheetAtURL:appending: named, with the folder
// the user picked for it (FolderSession's).
- (void)openSheetURL:(NSURL *)sheetURL inGrantedFolder:(NSURL *)folderURL appending:(BOOL)appending;

// Unloads everything, the twin of the mac's File > Close: the player, the
// session with its scopes and persisted bookmarks (the next launch restores
// nothing), the model, the sweep. Safe where a partial edit is not because it
// is the whole playlist: no cursor survives to strand.
- (void)clearPlaylist;

// Appends without touching playback, the tab or the card. An Add onto nothing
// is an Open (FolderSession).
- (void)addURLs:(NSArray<NSURL *> *)urls;

// For a caller with asynchronous work before it has a URL: take the token when
// the USER asks, so an Add a replace has since superseded is dropped.
- (uint64_t)addRequestToken;
- (void)addURLs:(NSArray<NSURL *> *)urls token:(uint64_t)token;

// A replace's own identity, taken when the USER asks and judged by the
// browser's confirmReplacing… funnel. Taking one supersedes every replace
// still waiting, as an open or a clear does, so of two taps whose
// resolves finish in either order only the later one opens. Not the Add
// token: two taps before either resolved captured the same generation, and
// the first to open dropped the one the user chose last. Main thread.
- (uint64_t)replaceRequestToken;
- (BOOL)isCurrentReplaceRequest:(uint64_t)token;

// YES once an Add has landed on the playlist now loaded, or it was restored
// with additions: replacing it loses work a reopen does not bring back.
@property (nonatomic, readonly) BOOL playlistHasAdditions;

// Nil for a single-file playlist and before anything was opened.
@property (nonatomic, readonly, nullable) NSURL *folderURL;

// Mints a bookmark for folderURL; only the session holds its scope.
// Completion on main, both nil when there is no folder or the mint failed.
- (void)bookmarkOpenFolderWithCompletion:(void (^)(NSURL *_Nullable folderURL,
                                                   NSData *_Nullable bookmark))completion;

// The same mint for a folder the session does not own (a Files-tab star).
// Completion on main, nil when the mint failed.
- (void)bookmarkFolderURL:(NSURL *)folderURL
               completion:(void (^)(NSData *_Nullable bookmark))completion;

// Every tree the search screen may walk: the session's, then Settings' and
// Documents, then resolved favorites. FileSearchIndex prunes nesting.
@property (nonatomic, readonly) NSArray<NSURL *> *searchRoots;

// A search hit or a recent (FolderSession openURL:inFolder:): a folder opens,
// a file plays alone or, inFolder, its directory with it selected.
- (void)openFileURL:(NSURL *)url inFolder:(BOOL)inFolder;

// FolderSession's recents, newest first, and their resolve.
@property (nonatomic, readonly) NSArray<NSDictionary *> *recentItems;
- (void)resolveRecentItem:(NSDictionary *)item completion:(void (^)(NSURL *_Nullable url))completion;
- (void)clearRecentItems;

// The scene delegate calls exactly one of this and handleOpenURLContexts: at
// launch. Nothing to restore, or a failed restore, sends
// playbackHasNothingToRestore:.
- (void)restorePersistedSession;

@end

NS_ASSUME_NONNULL_END
