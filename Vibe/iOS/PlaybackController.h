//
//  PlaybackController.h
//  Vibe (iOS)
//
//  Everything the iOS app plays, and nothing that draws it: the engine, the
//  playlist, the metadata cache, the audio session, the folder session, the
//  Now Playing bridge and the position timer, plus the display state those
//  resolve to (PlayerScreenRules.h). It is the model half of what the mac's
//  MainPlayerController is; the view half is PlayerViewController and the
//  screens beside it.
//
//  IT BROADCASTS, where the rest of the app uses a single weak delegate. That
//  is deliberate and it is the reason this class exists: three views describe
//  the same playback at once — the library's playing row, the mini player and
//  the full-screen card — and Playlist has exactly one observer slot, so the
//  fan-out had to live somewhere. Observers are held weakly and delivered to
//  synchronously on the main thread, in registration order.
//
//  Main thread only. Every callback below lands there, and every method here
//  is called from there.
//

#import <UIKit/UIKit.h>

#import "EqualizerIndicatorView.h"   // EqualizerLevelSource, adopted below
#import "PlayerScreenRules.h"        // VibePlayerScreenState, returned below

@class AudioTrack;
@class PlaybackController;
@class Playlist;

NS_ASSUME_NONNULL_BEGIN

@protocol PlaybackObserver <NSObject>
@optional

#pragma mark Playlist structure

// The whole row set changed and the cursor is back at 0.
- (void)playbackDidReplacePlaylist:(PlaybackController *)playback;
- (void)playback:(PlaybackController *)playback didAppendTracksAtIndexes:(NSIndexSet *)indexes;
- (void)playback:(PlaybackController *)playback didReplaceTrackAtIndex:(NSUInteger)index;
- (void)playback:(PlaybackController *)playback
        didChangeCurrentIndexFromIndex:(NSUInteger)previousIndex;

#pragma mark The current track

// The cursor arrived on a track the player is about to run: scroll to it, load
// its waveform. Always preceded by playbackDidRenderCurrentTrack:, except on a
// gapless splice, where the render follows with the rest of the start.
- (void)playbackDidMoveToCurrentTrack:(PlaybackController *)playback animated:(BOOL)animated;

// The current track's presentation is stale and must be drawn afresh: a new
// play, a park, a start landing, a failure.
- (void)playbackDidRenderCurrentTrack:(PlaybackController *)playback;

// Playing, paused, parked, empty — anything the transport glyph, the chrome or
// a display link keys off.
- (void)playbackDidChangePlayState:(PlaybackController *)playback;

// The position tick: time labels and progress. Fires at 3 Hz while playing and
// once for every event that moves the playhead.
- (void)playbackDidTick:(PlaybackController *)playback;

#pragma mark The current track's open

- (void)playbackDidBeginLoading:(PlaybackController *)playback;
// A materializing cloud file's best-effort fill; negative removes it.
- (void)playback:(PlaybackController *)playback didUpdateLoadingProgress:(float)fraction;
- (void)playbackDidFinishLoading:(PlaybackController *)playback;
- (void)playbackDidFailCurrentTrack:(PlaybackController *)playback;

#pragma mark Deliveries and the folder session

- (void)playback:(PlaybackController *)playback didLoadMetadataForTrack:(AudioTrack *)track;
// A deliberate open landed and is playing. A relaunch restore does NOT send
// this: it parks, and nothing was asked for. The shell presents the
// full-screen card on this and on nothing else.
- (void)playbackDidOpenNewFolder:(PlaybackController *)playback;
// The picked location held no audio files.
- (void)playbackDidOpenEmptyFolder:(PlaybackController *)playback;
// A relaunch restore came to nothing, or there was nothing to restore.
- (void)playbackHasNothingToRestore:(PlaybackController *)playback;

@end

// It is the app's EqualizerLevelSource as well: the library row's indicator
// draws the audio this object is playing, and this is the only thing that
// holds the player. The protocol is one method wide precisely so the shared
// control needs nothing else from here.
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

// Resolved in one place: every screen reads this rather than re-deriving it.
// The rule is VibeResolvePlayerScreenState, beside the enum it returns.
@property (nonatomic, readonly) VibePlayerScreenState screenState;
// The track the screens are describing — nil in the empty and error states.
@property (nonatomic, readonly, nullable) AudioTrack *displayedTrack;
// An inline playback error, shown on the artist line until the next track
// event.
@property (nonatomic, readonly, nullable) NSString *errorText;

#pragma mark - The player, non-blocking reads

// YES while the now-playing card covers the library, so the band-level tap can
// be switched off with it. The shell has to say so: the card moves by transform
// over children that stay in the hierarchy and stay "appeared", so no view under
// it ever learns it was covered. See RootViewController.
@property (nonatomic) BOOL levelsOccluded;

@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) NSTimeInterval position;
@property (nonatomic, readonly) NSTimeInterval duration;

// seekToPosition: fades down before rescheduling, so position briefly reports
// the pre-seek value; holding the target until didFinishSeeking: keeps a
// waveform from snapping back for those frames.
@property (nonatomic, readonly) BOOL seekInFlight;
@property (nonatomic, readonly) float pendingSeekProgress;

#pragma mark - Transport

// Every surface — the screens, the lock screen, the debug channel — comes
// through these, so no two can take different paths to the same action.
- (void)playCurrentTrack;
- (void)playPause;
- (void)next;
- (void)previous;
// The one selection funnel. Clamped: a list's rows can be stale, and
// Playlist.setCurrentIndex does not range-check.
- (void)selectTrackAtIndex:(NSUInteger)index;
- (void)seekToProgress:(float)progress;
- (void)seekToPosition:(NSTimeInterval)position;

// The priority metadata lane, for a screen that needs one track's tags before
// the playlist-wide scan would reach them — the pager's art prefetch, whose
// dispatch hangs off the metadata object. A no-op once the track is parsed.
- (void)loadMetadataNowForTrack:(nullable AudioTrack *)track;

#pragma mark - Opening

- (void)presentPickerFromViewController:(UIViewController *)presenter;

// "Open in Vibe" from Files or the share sheet, forwarded by the scene
// delegate.
- (void)handleOpenURLContexts:(NSSet<UIOpenURLContext *> *)contexts;

// One URL adopted from outside the picker: the Files tab's browser, or a share
// sheet. openInPlace mirrors UIOpenURLContext.options — YES means the real
// file, so the security scope covers the folder it came from and the usual
// expand-to-directory applies.
- (void)openExternalURL:(NSURL *)url openInPlace:(BOOL)openInPlace;

// The file trees the search screen may walk, composed in one place: the
// session's transient root (FolderSession.searchRoot — the open folder) plus the
// persistent ones (SearchFolderStore.searchRoots — the folders the user added in
// Settings, and the app's own Documents directory). Nesting among them is
// FileSearchIndex's to prune.
@property (nonatomic, readonly) NSArray<NSURL *> *searchRoots;

// A file the search screen found under one of searchRoots. Its own directory
// becomes the playlist with it selected, so observers see a new folder open —
// the card presents, exactly as any other open does.
- (void)openSearchResultURL:(NSURL *)url;

// Restores the persisted folder session. The scene delegate calls exactly one
// of this and handleOpenURLContexts: at launch — a cold "Open in Vibe" must
// not pay for (and then discard) a full restore. With nothing to restore, or
// on a failed one, observers get playbackHasNothingToRestore:.
- (void)restorePersistedSession;

@end

NS_ASSUME_NONNULL_END
