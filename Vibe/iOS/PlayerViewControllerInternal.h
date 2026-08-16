//
//  PlayerViewControllerInternal.h
//  Vibe (iOS)
//
//  The private surface shared between PlayerViewController.m and its
//  categories: the class extension holding the collaborators, the chrome
//  bindings, the state flags a category touches, and the internal methods the
//  categories call. Do not use it outside the PlayerViewController
//  implementation files; everything else goes through PlayerViewController.h.
//
//  The debug command channel is deliberately NOT here: its extra surface stays
//  in Debug/iOS/PlayerViewController+Debug.h, so that no production file
//  carries a declaration for a tool that does not ship.
//
//  This header is the cost of the split, so it is the thing to watch: a
//  category that would push more state into it than it takes out of
//  PlayerViewController.m is not worth making.
//

#import "PlayerViewController.h"
#import "AudioSessionController.h"  // AudioSessionControllerDelegate, adopted below
#import "FolderSession.h"           // FolderSessionDelegate, adopted below
#import "PlayerScreenRules.h"       // VibePlayerScreenState, returned below
#import "Playlist.h"                // PlaylistObserver, adopted below

@class AudioPlayer;
@class AudioTrack;
@class AudioTrackMetadataCache;
@class AudioWaveformCache;
@class DownloadProgressMonitor;
@class NowPlayingController;
@class PageWaveformCoordinator;
@class SearchViewController;
@class TrackListViewController;
@class TrackPageCell;
@class UIUpdateTimer;
@class WaveformScrubberView;

NS_ASSUME_NONNULL_BEGIN

// These four conformances stay on the class because PlayerViewController.m
// implements them. Every other one is declared on the category that implements
// it, so the compiler checks each against the file that holds it.
//
// Only the state a category also touches lives here; the rest — the empty
// state's midline, the bottom bar's buttons, the search sheet's handle and the
// scroll link itself — stays private to PlayerViewController.m.
@interface PlayerViewController () <PlaylistObserver, FolderSessionDelegate,
        AudioSessionControllerDelegate, UIGestureRecognizerDelegate> {
    AudioPlayer             *_player;
    Playlist                *_playlist;
    AudioTrackMetadataCache *_metadataCache;
    AudioWaveformCache      *_waveformCache;
    NowPlayingController    *_nowPlaying;
    AudioSessionController  *_audioSession;
    FolderSession           *_folderSession;
    UIUpdateTimer           *_updateTimer;

    // seekToPosition: fades down before rescheduling, so position briefly
    // reports the pre-seek value; holding the target until didFinishSeeking:
    // keeps the waveform from snapping back for those frames.
    float                   _pendingSeekProgress;
    BOOL                    _seekInFlight;
    // The same guard for a track change: until didStartPlaying: lands, the
    // player's getters still serve the OUTGOING track, so the new page's
    // waveform and time labels render the incoming track at rest instead of
    // the stale position (which then snapped to zero when the open landed).
    BOOL                    _trackStartPending;
    // A restored track is parked: header, waveform, and metadata are loaded,
    // but nothing plays until the user asks.
    BOOL                    _parked;
    // An inline playback error, shown on the artist line until the next track
    // event, exactly like the mac header.
    NSString                *_errorText;

    // The track pager, Photos-style: one full-screen cell per track (blurred
    // art + header), interactively draggable to the neighbors. The chrome —
    // waveform, transport, time, bottom bar — overlays it and never scrolls.
    // The screen is forced dark so text and the waveform read over any art.
    UICollectionView        *_pagesView;
    UICollectionViewFlowLayout *_pagesLayout;
    // A size transition (rotation, iPad window resize) is animating: the
    // pager's offset is not page-aligned at the new width, so commits hold.
    BOOL                    _windowResizeInFlight;
    // A page swipe is in flight (dragging or decelerating). It holds the
    // waveform machinery still for the duration — see the scroll hold in
    // PlayerViewController+Pager.m — and gates the playhead's display link.
    BOOL                    _pagerScrolling;
    // The last root size the pager was laid out for; layout passes at an
    // unchanged size skip the flow-layout invalidation.
    CGSize                  _lastLayoutSize;

    // Every page cell carries its own waveform view; these are BINDINGS to
    // the current page's views, rebound when the current cell appears or is
    // recreated, so the live-update paths (and the debug channel) keep one
    // stable name for "the playing track's waveform and time labels".
    TrackPageCell           *_boundPage;        // the current page the chrome bindings point into
    WaveformScrubberView    *_waveformView;
    UILabel                 *_elapsedLabel;
    UILabel                 *_remainingLabel;
    UIButton                *_playPauseButton;  // bound: the current page's glyph

    // The pager's waveform bookkeeping — the one load's target page, the
    // per-page snapshots, the complete set — between the cache and the cells.
    PageWaveformCoordinator    *_waveformCoordinator;

    // The pages whose full-size art is decoded and still held. The pager keeps
    // art up to a byte budget and releases the furthest pages past it; this is
    // the only record of what there is to release, since a page's art long
    // outlives the fetch window that asked for it. Owned by +Pager.
    NSMutableIndexSet       *_artHeldPages;

    // Polls a materializing cloud file's size while the loading indicator is
    // up; nil otherwise.
    DownloadProgressMonitor *_downloadMonitor;

    // Weak: presentation owns the sheet, and the reference exists only to
    // forward playlist changes while one is up — a dismissed sheet nils out
    // and the forwarding no-ops.
    __weak TrackListViewController *_trackListController;

    // The open hint, and whether the scene is foregrounded. Both are core
    // state; they are here because the debug channel's state dump reports
    // them (Debug/iOS/PlayerViewController+Debug.m).
    UILabel                 *_emptyHintLabel;
    BOOL                    _foreground;
}

#pragma mark - Display state

// The screen's display state, resolved in one place: the update funnel, the
// Now Playing publish and the debug channel all read this rather than
// re-deriving it from the flags. The rule is VibeResolvePlayerScreenState,
// beside the enum it returns; this gathers its inputs.
- (VibePlayerScreenState)screenState;

// The track the screen is describing — nil in the empty and error states.
- (nullable AudioTrack *)displayedTrack;

#pragma mark - The refresh funnel

// Implemented in PlayerViewController.m, which carries their contracts.

// The position tick: time labels, waveform progress, and the Now Playing
// publish.
- (void)updatePlaybackUI;
// The transport glyph's symbol and, through updateChrome, its visibility.
- (void)updatePlayButton;
// Playing hides the play glyph — a screen tap pauses — and pausing brings it
// back. The empty state shows none either.
- (CGFloat)chromeAlpha;
// The display link runs only while playing in the foreground.
- (void)updateScrollLinkState;
// The pager owns the header, art, and waveform; rendering the current track
// means refreshing its page and rebinding the live chrome to it.
- (void)renderHeaderForTrack:(nullable AudioTrack *)track;
// Keeps the empty-state line on the nominal waveform midline of whichever
// cell layout the current orientation uses.
- (void)aimEmptyLine;

#pragma mark - Resting time rendering

// The at-rest time rendering shared by neighbor pages, a pending track start,
// and a parked track the player has not opened: 0:00 elapsed, the full
// duration once metadata knows it.
+ (void)renderRestingTimesForTrack:(nullable AudioTrack *)track
                           elapsed:(UILabel *)elapsed
                         remaining:(UILabel *)remaining;
- (void)renderRestingTimesForTrack:(nullable AudioTrack *)track;

#pragma mark - Playback

- (void)playCurrentTrack;
- (void)playPauseTapped;
- (void)nextTapped;

@end

NS_ASSUME_NONNULL_END
