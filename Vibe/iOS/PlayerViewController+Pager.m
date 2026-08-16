//
//  PlayerViewController+Pager.m
//  Vibe (iOS)
//
//  See PlayerViewController+Pager.h. The rule that governs the whole file:
//  a page coming on screen loads its waveform but does NOT switch playback —
//  only the settled page commits, in commitVisiblePage.
//

#import "PlayerViewController+Pager.h"
#import "PlayerViewControllerInternal.h"
// willDisplayCell: makes self the scrubber's delegate, a conformance +Delivery
// declares.
#import "PlayerViewController+Delivery.h"
// The art window republishes the lock-screen card when the current page's art
// lands.
#import "PlaybackController+NowPlaying.h"

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadata+ArtLoad.h"
#import "PageWaveformCoordinator.h"
#import "TrackPageCell.h"
#import "WaveformScrubberView.h"

// How far either side of the current page art is loaded ahead. One would be
// enough if a swipe waited for the last one to land — the pager moves a single
// cell per gesture — but it does not, and each page's load is a file read and
// an ImageIO decode, so at radius one a quick second swipe outran the fetch and
// arrived on the placeholder. Two gives the fetch a whole extra commit of lead.
static const NSUInteger kArtPrefetchRadius = 2;

// What decoded art may occupy before the pages furthest from the current one
// are released. Retention is deliberately NOT the prefetch radius: fetching far
// ahead means file reads nobody asked for, while *keeping* what is already
// decoded costs only memory, and dropping it means re-reading and re-decoding
// the moment the user swipes back. At kVibeDisplayArtDimension a cover is about
// 4MB, so this holds a dozen — more pages than one browsing pass covers.
static const NSUInteger kArtBudgetBytes = 48 * 1024 * 1024;

@implementation PlayerViewController (Pager)

#pragma mark - Per-page waveforms

- (TrackPageCell *)cellAtIndex:(NSUInteger)index {
    return (TrackPageCell *)[_pagesView cellForItemAtIndexPath:
            [NSIndexPath indexPathForItem:(NSInteger)index inSection:0]];
}

// Points the live-update bindings at the current page's views.
- (void)bindChromeToCell:(TrackPageCell *)cell {
    if (!cell) {
        return;
    }
    _boundPage = cell;
    _waveformView = cell.waveformView;
    _elapsedLabel = cell.elapsedLabel;
    _remainingLabel = cell.remainingLabel;
    _playPauseButton = cell.playPauseButton;
    // A rebind means a fresh (or reloaded) cell whose labels came back at
    // their reuse defaults; while paused no timer tick will repopulate them,
    // so refresh now — the play glyph's symbol and visibility included.
    [self updatePlaybackUI];
    [self updatePlayButton];
}

- (void)requestWaveformForIndex:(NSUInteger)index {
    [_waveformCoordinator requestIndex:index track:[_playlist trackAtIndex:index]];
}

// Reloaded and recycled cells come back blank; the latest snapshot puts the
// waveform straight back without waiting for a fresh decode. With no
// snapshot in hand the page animates the loading line instead of sitting
// blank — on a network folder the decode behind it is routinely slow — and
// showWaveform: ends the line when data arrives.
//
// Never animated: hydration re-shows a shape this page has already drawn, so
// the growing-bars morph would be a replay — and its per-frame rebuilds land
// on whatever swipe brought the cell back.
- (void)hydrateWaveformInCell:(TrackPageCell *)cell atIndex:(NSUInteger)index {
    CodableAudioWaveform *snapshot = [_waveformCoordinator snapshotAtIndex:index];
    if (snapshot) {
        [cell.waveformView showWaveform:snapshot animated:NO];
    }
    else {
        [cell.waveformView showLoadingIndicator];
    }
}

#pragma mark - Data source

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)_playlist.count;
}

// A page coming on screen: hydrate its waveform from the latest snapshot,
// and start (or re-target) the load so a neighbor pulled into view arrives
// with its own track's waveform loading. Playback does NOT switch here —
// only the settled page commits, in commitVisiblePage.
//
// Mid-drag the coordinator's scroll hold drops that request: retargeting the
// one load per page swiped past leaves every decode cancelled and none
// finished. The page shows what it has until the scroll settles.
- (void)collectionView:(UICollectionView *)collectionView
       willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    TrackPageCell *page = (TrackPageCell *)cell;
    NSUInteger index = (NSUInteger)indexPath.item;

    if (page.waveformView.delegate != self) {
        page.waveformView.delegate = self;
        // The pager yields horizontal drags on the waveform surface to the
        // scrubber; page-drag starts anywhere else.
        for (UIGestureRecognizer *recognizer in page.waveformView.gestureRecognizers) {
            if ([recognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
                [_pagesView.panGestureRecognizer requireGestureRecognizerToFail:recognizer];
            }
        }
        [page.playPauseButton addTarget:self action:@selector(playPauseTapped)
                       forControlEvents:UIControlEventTouchUpInside];
    }

    [self hydrateWaveformInCell:page atIndex:index];
    if (![_waveformCoordinator isCompleteAtIndex:index]) {
        [self requestWaveformForIndex:index];
    }

    if (index == _playlist.currentIndex) {
        [self bindChromeToCell:page];
    }
    else {
        // A neighbor at rest: track start, and the duration once metadata
        // knows it.
        [PlayerViewController renderRestingTimesForTrack:[_playlist trackAtIndex:index]
                                                 elapsed:page.elapsedLabel
                                               remaining:page.remainingLabel];
    }
}

- (void)configurePage:(TrackPageCell *)cell atIndex:(NSUInteger)index {
    AudioTrack *track = [_playlist trackAtIndex:index];
    NSString *errorText = _playback.errorText;
    BOOL showError = index == _playlist.currentIndex && errorText != nil;
    // Full-size art, and nothing standing in for it. The 128px thumbnail is
    // fine under the blur but visibly soft in the art card, and installing it
    // first only buys a swap to sharp a moment later; the art window is what
    // makes the real thing arrive before the page does. Until then, and for a
    // track with no art at all, the mac's vinyl placeholder.
    [cell configureWithTitle:track.displayTitle
                  titleColor:[UIColor labelColor]
                      artist:(showError ? errorText : (track.displayArtist ?: @""))
                 artistColor:(showError ? [UIColor systemRedColor]
                                        : [UIColor secondaryLabelColor])
                    fileInfo:track.metadata.fileInfoLine
                         art:(track.cachedArt ?: [UIImage imageNamed:@"record-bg"])];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    TrackPageCell *cell = [collectionView
            dequeueReusableCellWithReuseIdentifier:TrackPageCell.reuseIdentifier
                                      forIndexPath:indexPath];
    [self configurePage:cell atIndex:(NSUInteger)indexPath.item];
    // Reuse hands back the glyph at its resting look; stamp the live chrome
    // state so a page never appears with the wrong visibility.
    cell.playPauseButton.alpha = [self chromeAlpha];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return _pagesView.bounds.size;
}

#pragma mark - Layout and size transitions

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Page size follows the view, and the offset must stay page-aligned
    // through the first layout after a restore. Only on a real size change:
    // this runs on every root layout pass (sheet presentations, safe-area
    // churn), and an unconditional invalidation re-prepares the whole layout
    // each time.
    CGSize size = self.view.bounds.size;
    if (CGSizeEqualToSize(size, _lastLayoutSize)) {
        return;
    }
    _lastLayoutSize = size;
    [_pagesLayout invalidateLayout];
    if (!_pagesView.isDragging && !_pagesView.isDecelerating) {
        [self scrollToCurrentPageAnimated:NO];
    }
}

// Rotation and window resize: re-page alongside the transition so the
// current page stays centered instead of the offset landing between pages at
// the new width. The in-flight flag keeps commitVisiblePage from rounding a
// mid-resize offset to a neighbor page — which would switch tracks.
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    _windowResizeInFlight = YES;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self->_pagesLayout invalidateLayout];
        [self scrollToCurrentPageAnimated:NO];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        self->_windowResizeInFlight = NO;
        [self scrollToCurrentPageAnimated:NO];
    }];
}

- (void)scrollToCurrentPageAnimated:(BOOL)animated {
    CGFloat width = _pagesView.bounds.size.width;
    if (width <= 0 || _playlist.count == 0) {
        return;
    }
    CGPoint target = CGPointMake(width * (CGFloat)_playlist.currentIndex, 0);
    if (!CGPointEqualToPoint(_pagesView.contentOffset, target)) {
        [_pagesView setContentOffset:target animated:animated];
    }
}

// In place when the page has a live cell: reloadItemsAtIndexPaths: swaps the
// full-screen cell with a crossfade — the whole blurred backdrop dims on
// every track commit and metadata/art delivery — and recycles the waveform
// with it. Pages without a cell reload so a prefetched one cannot come on
// screen stale.
- (void)refreshPageAtIndex:(NSUInteger)index {
    if (index >= _playlist.count) {
        return;
    }
    TrackPageCell *cell = [self cellAtIndex:index];
    if (cell) {
        [self configurePage:cell atIndex:index];
    }
    else {
        [_pagesView reloadItemsAtIndexPaths:
                @[[NSIndexPath indexPathForItem:(NSInteger)index inSection:0]]];
    }
}

#pragma mark - The art window

// The pages fetched ahead, clamped to the playlist.
- (NSRange)artWindow {
    NSUInteger count = _playlist.count;
    if (count == 0) {
        return NSMakeRange(0, 0);
    }
    NSUInteger current = MIN(_playlist.currentIndex, count - 1);
    NSUInteger first = current > kArtPrefetchRadius ? current - kArtPrefetchRadius : 0;
    NSUInteger last = MIN(current + kArtPrefetchRadius, count - 1);
    return NSMakeRange(first, last - first + 1);
}

// A decode outlives the page that asked for it — it is a file read and an
// ImageIO pass, and a commit or a playlist replacement can land in the middle
// of either. Both halves matter: the page must still be in the window, and it
// must still hold the track the load was started for.
- (BOOL)artStillWantedForTrack:(AudioTrack *)track atIndex:(NSUInteger)index {
    return NSLocationInRange(index, [self artWindow]) &&
           [_playlist trackAtIndex:index] == track;
}

// Everything a page needs to arrive already drawn, in the order it is needed.
// The metadata comes first and through the PRIORITY lane, not because the page
// wants its tags sooner but because the art dispatch below hangs off the
// metadata object: behind a playlist-wide scan of a cloud folder, a page's own
// tags can be minutes away, and until they land its art cannot even start.
- (void)prefetchPageAtIndex:(NSUInteger)index {
    AudioTrack *track = [_playlist trackAtIndex:index];
    if (!track) {
        return;
    }
    [_playback loadMetadataNowForTrack:track];   // no-op once parsed
    __weak PlayerViewController *weakSelf = self;
    [track.metadata dispatchArtLoadIfNeededStillWanted:^BOOL{
        // A dead controller answers "not wanted", which demotes the decode.
        return [weakSelf artStillWantedForTrack:track atIndex:index];
    } completion:^(VibeImage *loaded) {
        PlayerViewController *self = weakSelf;
        if (!self || !loaded) {
            return;
        }
        [self->_artHeldPages addIndex:index];
        [self refreshPageAtIndex:index];
        if ([self->_playlist isCurrentTrack:track]) {
            [self->_playback publishNowPlaying];  // the card takes the art too
        }
    }];
}

- (void)refreshArtWindow {
    NSRange window = [self artWindow];
    for (NSUInteger index = window.location; index < NSMaxRange(window); index++) {
        [self prefetchPageAtIndex:index];
    }
    [self releaseArtBeyondBudget];
}

// What one page's decoded art occupies. Zero for a page holding none, so a
// stale entry — a page whose metadata object was replaced under its art — costs
// nothing and drops out of the set here.
- (NSUInteger)artBytesAtIndex:(NSUInteger)index {
    CGImageRef image = [_playlist trackAtIndex:index].cachedArt.CGImage;
    return image ? CGImageGetBytesPerRow(image) * CGImageGetHeight(image) : 0;
}

// Releases held art, furthest page from the current one first, until the rest
// fits the budget. Distance is the eviction order rather than true recency
// because in a pager they are the same thing: pages are reached one step at a
// time, so the furthest page is the one longest since seen and the one furthest
// from being seen again.
- (void)releaseArtBeyondBudget {
    NSRange window = [self artWindow];
    NSUInteger current = _playlist.currentIndex;
    NSArray<NSNumber *> *held = [self heldArtPagesByDistanceFrom:current];
    NSUInteger total = 0;
    for (NSNumber *page in held) {
        total += [self artBytesAtIndex:page.unsignedIntegerValue];
    }
    for (NSNumber *page in held) {
        if (total <= kArtBudgetBytes) {
            break;
        }
        NSUInteger index = page.unsignedIntegerValue;
        NSUInteger bytes = [self artBytesAtIndex:index];
        if (bytes == 0) {
            [_artHeldPages removeIndex:index];   // nothing there to release
            continue;
        }
        // A page still on screen keeps its art whatever the budget says: its
        // image view holds the bitmap either way, so releasing it would free
        // nothing while leaving the page one reconfigure away from dropping to
        // the placeholder in full view. It stays in the set, and a later pass
        // collects it once the cell is recycled.
        if (NSLocationInRange(index, window) || [self cellAtIndex:index]) {
            continue;
        }
        [[_playlist trackAtIndex:index].metadata discardDecodedArt];
        [_artHeldPages removeIndex:index];
        total -= bytes;
    }
}

- (NSArray<NSNumber *> *)heldArtPagesByDistanceFrom:(NSUInteger)current {
    NSMutableArray<NSNumber *> *pages = [NSMutableArray arrayWithCapacity:_artHeldPages.count];
    [_artHeldPages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [pages addObject:@(index)];
    }];
    return [pages sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSUInteger da = a.unsignedIntegerValue > current ? a.unsignedIntegerValue - current
                                                         : current - a.unsignedIntegerValue;
        NSUInteger db = b.unsignedIntegerValue > current ? b.unsignedIntegerValue - current
                                                         : current - b.unsignedIntegerValue;
        if (da != db) {
            return da > db ? NSOrderedAscending : NSOrderedDescending;  // furthest first
        }
        return NSOrderedSame;
    }];
}

#pragma mark - Committing a page

// The grab-and-pull commit, Photos semantics: whatever page the drag settles
// on becomes the current track; pulling back to the same page changes
// nothing.
- (void)commitVisiblePage {
    CGFloat width = _pagesView.bounds.size.width;
    // Minimized, the card is still laid out and still reloads: a playlist
    // replacement settles a scroll nobody performed, and committing it would
    // change track under a user looking at the library.
    if (width <= 0 || _playlist.count == 0 || _windowResizeInFlight || !self.isPresented) {
        return;
    }
    NSUInteger page = (NSUInteger)MAX(0.0, round(_pagesView.contentOffset.x / width));
    page = MIN(page, _playlist.count - 1);
    if (page != _playlist.currentIndex) {
        [_playback selectTrackAtIndex:page];
    }
    else if (_waveformCoordinator.targetIndex != page) {
        // Pulled a neighbor into view and let go: the preview load retargeted
        // the pipeline, so point it back at the current page (a no-op reload
        // when its waveform had already fully arrived).
        [self requestWaveformForIndex:page];
    }
}

#pragma mark - The scroll hold

// A swipe is the one moment the main thread has nothing to spare, so for its
// duration the waveform machinery stands still: the coordinator holds
// deliveries and requests (see its `held`), and the playhead's display link
// pauses — its per-frame translation is invisible under a moving page, and it
// resumes on the settled track's position anyway. UIScrollView always follows
// a drag with exactly one of the two end callbacks below, so the hold cannot
// be stranded on.
- (void)holdForPagerScrolling:(BOOL)scrolling {
    if (_pagerScrolling == scrolling) {
        return;
    }
    _pagerScrolling = scrolling;
    _waveformCoordinator.held = scrolling;
    [self updateScrollLinkState];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self holdForPagerScrolling:YES];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    // Release before the commit: the settled page's request has to get through.
    [self holdForPagerScrolling:NO];
    [self commitVisiblePage];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self holdForPagerScrolling:NO];
        [self commitVisiblePage];
    }
}

@end
