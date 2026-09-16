//
//  PlayerViewController+Pager.h
//  Vibe (iOS)
//
//  The track pager: one full-screen cell per track, Photos semantics — a
//  grab-and-pull to a neighbor commits that track when the scroll settles, and
//  pulling back cancels. It owns the collection view's data source and layout,
//  the size-transition re-paging, and the per-page waveform bookkeeping
//  between the coordinator and the cells.
//
//  Playback does NOT switch as pages come on screen; only the settled page
//  commits, in commitVisiblePage.
//
//  It also owns the art window — which pages hold decoded full-size art —
//  because a page shows full-size art and nothing else, and the window is what
//  makes that arrive before the page does. See refreshArtWindow.
//

#import "PlayerViewController.h"

@class CodableAudioWaveform;
@class TrackPageCell;

NS_ASSUME_NONNULL_BEGIN

@interface PlayerViewController (Pager) <UICollectionViewDataSource,
        UICollectionViewDelegate>

// The live cell for a page, or nil when that page has none on screen.
- (nullable TrackPageCell *)cellAtIndex:(NSUInteger)index;

// Points the live-update bindings at the current page's views.
- (void)bindChromeToCell:(nullable TrackPageCell *)cell;

// Renders one page from its track: header, art, and the transport's end-of-
// playlist state. The data source's own path, and the way a live cell is
// repainted in place when what it draws — not what it plays — has changed.
- (void)configurePage:(TrackPageCell *)cell atIndex:(NSUInteger)index;

// Starts, or re-targets, the one waveform load at this page.
- (void)requestWaveformForIndex:(NSUInteger)index;

// Repaints a cell from the latest snapshot, or starts the loading line when
// there is none yet.
- (void)hydrateWaveformInCell:(nullable TrackPageCell *)cell atIndex:(NSUInteger)index;

// Re-renders one page in place when it has a live cell. An off-screen cell is
// configured from current model state on its way back on screen, in
// willDisplayCell: — dequeue alone is not enough, since the pager prefetches.
- (void)refreshPageAtIndex:(NSUInteger)index;

// Moves the art window to the current page: decodes full-size art for it and
// its neighbors, and releases whatever fell outside. Call it whenever the
// current page moves, and again when a page's metadata lands — a track with no
// metadata yet cannot say whether it has art at all, so its dispatch is a
// message to nil.
- (void)refreshArtWindow;

// The pages the window currently covers. Empty for an empty playlist. Exposed
// for the debug channel's dump_art.
- (NSRange)artWindow;

- (void)scrollToCurrentPageAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
