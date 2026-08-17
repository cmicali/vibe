//
//  PlayerViewControllerInternal.h
//  Vibe (iOS)
//
//  The private surface shared between PlayerViewController.m and its
//  categories: the class extension holding the pager and its bookkeeping, the
//  chrome bindings, the state flags a category touches, and the internal
//  methods the categories call. Do not use it outside the PlayerViewController
//  implementation files; everything else goes through PlayerViewController.h.
//
//  Everything the screen DESCRIBES rather than draws — the engine, the
//  playlist, the caches, the session, the display state — belongs to
//  PlaybackController, which this reads through `_playback`.
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
#import "PlaybackController.h"      // PlaybackObserver, adopted below
#import "PlayerDisplaySettings.h"   // the two display preferences, read below
#import "PlayerScreenRules.h"       // VibePlayerScreenState, read below
#import "Playlist.h"

@class AudioTrack;
@class AudioWaveformCache;
@class PageWaveformCoordinator;
@class TrackPageCell;
@class VibeTimeControl;
@class WaveformScrubberView;

NS_ASSUME_NONNULL_BEGIN

// The right time label's text in whichever mode PlayerDisplaySettings holds.
// Every render path — the tick, a page at rest, a scrub — goes through this,
// so the three cannot disagree.
NSString *VibeRightTimeText(NSTimeInterval position, NSTimeInterval duration);

// These two conformances stay on the class because PlayerViewController.m
// implements them. Every other one is declared on the category that implements
// it, so the compiler checks each against the file that holds it.
@interface PlayerViewController () <PlaybackObserver, UIGestureRecognizerDelegate> {
    PlaybackController      *_playback;
    // Borrowed from _playback, which owns the one instance for the process.
    // Held by name because the pager reads it on every data-source callback.
    Playlist                *_playlist;

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
    // A visible programmatic page animation takes the same frame-budget hold.
    // Minimized page moves snap and never set it.
    BOOL                    _pagerProgrammaticScrolling;
    // Tags each take of that hold, so the bounded release armed with it cannot
    // lift a later one. See holdForProgrammaticPagerScrolling:.
    uint64_t                _pagerProgrammaticScrollGeneration;
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
    VibeTimeControl         *_remainingTimeControl;
    UIView                  *_transportView;    // bound: the current page's transport row
    // Whichever scrubber currently holds the pager still, which is NOT always
    // the bound page's: playback runs on through a scrub, so a track ending
    // mid-drag rebinds the chrome above while the finger is still down on the
    // outgoing page. The release has to be honored from the view that took it.
    __weak WaveformScrubberView *_scrubbingView;

    // The waveform data and the pager's bookkeeping over it — the one load's
    // target page, the per-page snapshots, the complete set — between the
    // cache and the cells. Both are the pager's own, not the model's: nothing
    // outside this screen draws a waveform.
    AudioWaveformCache      *_waveformCache;
    PageWaveformCoordinator *_waveformCoordinator;

    // The pages whose full-size art is decoded and still held. The pager keeps
    // art up to a byte budget and releases the furthest pages past it; this is
    // the only record of what there is to release, since a page's art long
    // outlives the fetch window that asked for it. Owned by +Pager.
    NSMutableIndexSet       *_artHeldPages;

    // Whether the scene is foregrounded. Core state, here because the debug
    // channel's state dump reports it.
    BOOL                    _foreground;

    // The whole second the time labels last rendered for a scrub. The scrub
    // position arrives per frame of scroll and the labels show seconds, so
    // this is what keeps a drag from formatting two strings at display rate.
    // NSIntegerMin means "not scrubbing", so the first frame always renders.
    NSInteger               _scrubLabelSecond;

    // The waveform zoom, shared by every page's scrubber — the pager carries
    // one per cell, so a swipe would otherwise change it. This is the user's
    // REQUEST (see WaveformScrubberView.visibleFraction), which is what gets
    // persisted; each view applies its own geometry's floor to it.
    CGFloat                 _waveformZoom;
}

#pragma mark - The refresh funnel

// Implemented in PlayerViewController.m, which carries their contracts.

// The position tick: time labels and waveform progress.
- (void)updatePlaybackUI;
// The transport glyph's symbol and, through updateChrome, its visibility.
- (void)updatePlayButton;
// The transport row is up whenever there is something to play: only the empty
// state hides it.
- (CGFloat)chromeAlpha;
// The display link runs only while playing in the foreground.
- (void)updateScrollLinkState;
// The pager owns the header, art, and waveform; rendering the current track
// means refreshing its page and rebinding the live chrome to it.
- (void)renderHeaderForTrack:(nullable AudioTrack *)track;

#pragma mark - Resting time rendering

// The at-rest time rendering shared by neighbor pages, a pending track start,
// and a parked track the player has not opened: 0:00 elapsed, the full
// duration once metadata knows it.
+ (void)renderRestingTimesForTrack:(nullable AudioTrack *)track
                           elapsed:(UILabel *)elapsed
                         remaining:(VibeTimeControl *)remaining;
- (void)renderRestingTimesForTrack:(nullable AudioTrack *)track;

#pragma mark - Transport

// The page transport's targets — the play glyph's is the screen tap's too.
// All three forward to _playback, so every surface takes the one path.
- (void)playPauseTapped;
- (void)previousTapped;
- (void)nextTapped;

// The right time control flips total-vs-remaining and repaints every
// visible page, since the mode is one setting rather than the tapped page's.
- (void)remainingTimeTapped;

// The times on every visible page, in whichever mode is current. The bound
// page is left to updatePlaybackUI, which is live.
- (void)repaintTimesOnVisiblePages;

@end

NS_ASSUME_NONNULL_END
