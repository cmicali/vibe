//
//  PlayerViewController+Pager.h
//  Vibe (iOS)
//
//  The track pager, Photos semantics: only the settled page commits
//  (commitVisiblePage). It also owns the art window.
//

#import "PlayerViewController.h"

@class CodableAudioWaveform;
@class TrackPageCell;

NS_ASSUME_NONNULL_BEGIN

@interface PlayerViewController (Pager) <UICollectionViewDataSource,
        UICollectionViewDelegate>

// The live cell for a page, or nil when that page has none on screen.
- (nullable TrackPageCell *)cellAtIndex:(NSUInteger)index;

- (void)bindChromeToCell:(nullable TrackPageCell *)cell;

// Header, art and the end-of-playlist state, from the page's own track.
- (void)configurePage:(TrackPageCell *)cell atIndex:(NSUInteger)index;

- (void)requestWaveformForIndex:(NSUInteger)index;

// Repaints a cell from the latest snapshot, or starts the loading line when
// there is none yet.
- (void)hydrateWaveformInCell:(nullable TrackPageCell *)cell atIndex:(NSUInteger)index;

// Live cells only; willDisplayCell: covers the rest.
- (void)refreshPageAtIndex:(NSUInteger)index;

// Decodes full-size art around the current page and releases past the budget.
// Call it when the page moves and when a page's metadata lands: before that
// the dispatch is a message to nil.
- (void)refreshArtWindow;

- (NSRange)artWindow;

- (void)scrollToCurrentPageAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
