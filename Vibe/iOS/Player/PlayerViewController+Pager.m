//
//  PlayerViewController+Pager.m
//  Vibe (iOS)
//
//  Neighbor pages preview cached waveforms; only the settled page commits
//  playback and requests a decode, in commitVisiblePage.
//

#import "PlayerViewController+Pager.h"
#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Delivery.h"
#import "PlaybackController+NowPlaying.h"

#import "AppSettings.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "FXPadView.h"
#import "Formatters.h"
#import "PageWaveformCoordinator.h"
#import "TrackPageCell.h"
#import "WaveformScrubberView.h"
#import "NSURLUtil.h"
#import "UIImage+DominantColor.h"

// At one, a quick second swipe outruns the fetch (a file read and a decode)
// and lands on the placeholder; two gives a whole extra commit of lead.
static const NSUInteger kArtPrefetchRadius = 2;

// Retention is deliberately wider than the prefetch radius: keeping a decode
// costs only memory, dropping it costs a re-read on the swipe back. About a
// dozen covers at kVibeDisplayArtDimension.
static const NSUInteger kArtBudgetBytes = 48 * 1024 * 1024;

// A backstop for an end callback that never arrives; the animation runs well
// under half of it.
static const NSTimeInterval kProgrammaticScrollHoldCeilingSeconds = 1.5;

@implementation PlayerViewController (Pager)

#pragma mark - Per-page waveforms

- (TrackPageCell *)cellAtIndex:(NSUInteger)index {
    return (TrackPageCell *)[_pagesView cellForItemAtIndexPath:
            [NSIndexPath indexPathForItem:(NSInteger)index inSection:0]];
}

- (void)bindChromeToCell:(TrackPageCell *)cell {
    if (!cell) {
        return;
    }
    _boundPage = cell;
    _waveformView = cell.waveformView;
    _elapsedLabel = cell.elapsedLabel;
    _remainingTimeControl = cell.remainingTimeControl;
    _transportView = cell.transportView;
    _routeView = cell.routeView;
    _actionBar = cell.actionBar;
    _fxPadView = cell.fxPadView;
    // A fresh cell's labels are at their defaults, and paused, no tick comes.
    [self updatePlaybackUI];
    [self updatePlayButton];
    [self refreshWaveformWindow];
}

// A provider's dataless file is not asked for: its decode would hold a slot
// through the download, and playbackDidFinishLoading: asks again once the
// open lands. A remote placeholder is: its stat is the file's, so the cache
// answers for an evicted track parked at relaunch; a miss refuses the open at
// once (the page keeps its indicator; didFailWaveformForIndex:) unless a
// stream is live for it, when the decode rides the download the play holds.
// Either way the page starts no download of its own.
static BOOL WaveformWaitsForOpen(NSURL *url) {
    return [NSURLUtil isDatalessFile:url] && ![NSURLUtil isRemotePlaceholderFile:url];
}

- (void)requestWaveformForIndex:(NSUInteger)index {
    AudioTrack *track = [_playlist trackAtIndex:index];
    if (!track || WaveformWaitsForOpen(track.url)) {
        return;
    }
    [_waveformCoordinator requestIndex:index track:track];
    // TRAP: a page whose waveform is complete starts no load and DELIVERS
    // NOTHING, and a track change clears the widget's strip, so returning to a
    // played track would leave the widget blank. Offer the cached envelope; the
    // offer must be for the current track, including before its widget publish.
    if (index == _playlist.currentIndex && [_waveformCoordinator isCompleteAtIndex:index]) {
        [_playback offerWaveformToWidget:[_waveformCoordinator snapshotAtIndex:index]
                                forTrack:track];
    }
}

// A neighbor whose file is dataless shows nothing: requestWaveformForIndex:
// skips it and only the current page's open would ever take an indicator
// down. Its open, once current, shows one.
- (void)hydrateWaveformInCell:(TrackPageCell *)cell atIndex:(NSUInteger)index {
    CodableAudioWaveform *snapshot = [_waveformCoordinator snapshotAtIndex:index];
    if (snapshot) {
        [cell layoutIfNeeded];
        if (![cell.waveformView showPreparedWaveform:snapshot fromView:_preparedWaveforms[@(index)]]) {
            [cell.waveformView showWaveform:snapshot
                                  animated:![_waveformCoordinator isCompleteAtIndex:index]];
        }
        if (cell && index == _playlist.currentIndex) {
            [_preparedWaveforms[@(index)] removeFromSuperview];
            [_preparedWaveforms removeObjectForKey:@(index)];
        }
        return;
    }
    NSURL *url = [_playlist trackAtIndex:index].url;
    if (index != _playback.currentIndex && url && WaveformWaitsForOpen(url)) {
        [cell.waveformView hideLoadingIndicator];
        return;
    }
    [cell.waveformView showLoadingIndicator];
}

- (void)clearPreparedWaveforms {
    for (WaveformScrubberView *view in _preparedWaveforms.allValues) {
        [view removeFromSuperview];
    }
    [_preparedWaveforms removeAllObjects];
}

- (void)refreshWaveformWindow {
    if (!self.isPresented || _waveformCoordinator.isHeld || !_waveformView || _playlist.count == 0) {
        return;
    }
    [_boundPage layoutIfNeeded];
    CGSize size = _waveformView.bounds.size;
    if (size.width <= 0 || size.height <= 0) {
        return;
    }
    NSUInteger current = _playlist.currentIndex;
    [_waveformCoordinator pruneAroundIndex:current];
    NSUInteger first = current > 0 ? current - 1 : 0;
    NSUInteger last = MIN(current + 1, _playlist.count - 1);
    for (NSNumber *key in _preparedWaveforms.allKeys) {
        // Next updates the cursor before the arriving cell can adopt its image.
        if (key.unsignedIntegerValue < first || key.unsignedIntegerValue > last) {
            [_preparedWaveforms[key] removeFromSuperview];
            [_preparedWaveforms removeObjectForKey:key];
        }
    }
    for (NSUInteger index = first; index <= last; index++) {
        AudioTrack *track = [_playlist trackAtIndex:index];
        if (index != current) {
            [_waveformCoordinator prefetchIndex:index track:track];
        }
        if (index == current || ![_waveformCoordinator isCompleteAtIndex:index]) {
            continue;
        }
        WaveformScrubberView *view = _preparedWaveforms[@(index)];
        if (!view) {
            view = [[WaveformScrubberView alloc] initWithFrame:(CGRect){CGPointZero, size}];
            view.hidden = YES;
            // Inherit the card's appearance and display scale offscreen.
            [self.view addSubview:view];
            _preparedWaveforms[@(index)] = view;
        }
        view.frame = (CGRect){CGPointZero, size};
        view.visibleFraction = _waveformZoom;
        view.artworkThemeColor = [self artworkForPageAtIndex:index].vibeDominantColor;
        [view syncWaveformStyle];
        [view syncWaveformTheme];
        [view layoutIfNeeded];
        CodableAudioWaveform *snapshot = [_waveformCoordinator snapshotAtIndex:index];
        if (![view showPreparedWaveform:snapshot fromView:[self cellAtIndex:index].waveformView]) {
            [view showWaveform:snapshot animated:NO];
        }
    }
}

#pragma mark - Data source

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)_playlist.count;
}

// UIKit can display prepared neighbors before a swipe settles. Only the
// current page may retarget the decoder; the others use the cache window.
- (void)collectionView:(UICollectionView *)collectionView
       willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    TrackPageCell *page = (TrackPageCell *)cell;
    NSUInteger index = (NSUInteger)indexPath.item;

    // TRAP: dequeue is NOT the last word. A prefetched page is configured off
    // screen and misses deliveries, since refreshPageAtIndex: reaches only live
    // cells.
    [self configurePage:page atIndex:index];

    if (page.waveformView.delegate != self) {
        page.waveformView.delegate = self;
        // With no waveform the scrubber's pan refuses to begin, so the swipe
        // falls through to the pager.
        [_pagesView.panGestureRecognizer
                requireGestureRecognizerToFail:page.waveformView.scrubPanRecognizer];
        // A pan that begins with one finger and becomes a pinch.
        [_pagesView.panGestureRecognizer
                requireGestureRecognizerToFail:page.waveformView.zoomPinchRecognizer];
        [page.previousButton addTarget:self action:@selector(previousTapped)
                      forControlEvents:UIControlEventTouchUpInside];
        [page.playPauseButton addTarget:self action:@selector(playPauseTapped)
                       forControlEvents:UIControlEventTouchUpInside];
        [page.nextButton addTarget:self action:@selector(nextTapped)
                  forControlEvents:UIControlEventTouchUpInside];
        [page.shuffleButton addTarget:self action:@selector(shuffleTapped)
                     forControlEvents:UIControlEventTouchUpInside];
        [page.repeatButton addTarget:self action:@selector(repeatTapped)
                    forControlEvents:UIControlEventTouchUpInside];
        [page.remainingTimeControl addTarget:self action:@selector(remainingTimeTapped)
                           forControlEvents:UIControlEventTouchUpInside];
        page.routeView.delegate = self;
        // The FX pad owns its touch from the press, the way the scrubber owns
        // a drag: the pager's pan waits for it to fail, and its positions
        // reach the model through the card.
        page.fxPadView.delegate = self;
        [_pagesView.panGestureRecognizer
                requireGestureRecognizerToFail:page.fxPadView.pressRecognizer];
    }

    // Every time: a recycled cell keeps whatever it was last shown at. Each
    // no-ops when it already matches.
    [self applyWaveformZoomToCell:page];
    [page.waveformView syncWaveformStyle];
    [page.waveformView syncWaveformTheme];

    BOOL loading = _playbackLoadingTrack && index == _playlist.currentIndex
            && [_playlist trackAtIndex:index] == _playbackLoadingTrack;
    if (page.waveformView.playbackLoading != loading) {
        page.waveformView.playbackLoading = loading;
    }
    [self hydrateWaveformInCell:page atIndex:index];
    if (index == _playlist.currentIndex && ![_waveformCoordinator isCompleteAtIndex:index]) {
        [self requestWaveformForIndex:index];
    }

    if (index == _playlist.currentIndex) {
        [self bindChromeToCell:page];
    }
    else {
        // Rest at the start, as the labels do: committing a page plays from
        // the top (Player/AGENTS.md).
        page.waveformView.progress = 0;
        [PlayerViewController renderRestingTimesForTrack:[_playlist trackAtIndex:index]
                                                 elapsed:page.elapsedLabel
                                               remaining:page.remainingTimeControl];
    }
}

- (UIImage *)artworkForPageAtIndex:(NSUInteger)index {
    return [_playlist trackAtIndex:index].cachedArt ?: [UIImage imageNamed:@"record-bg"];
}

- (void)configurePage:(TrackPageCell *)cell atIndex:(NSUInteger)index {
    AudioTrack *track = [_playlist trackAtIndex:index];
    NSString *errorText = _playback.errorText;
    BOOL showError = index == _playlist.currentIndex && errorText != nil;
    BOOL showsInfo = AppSettings.sharedInstance.showFileInfo;
    // Full-size art or the placeholder, never the soft 128px thumbnail.
    [cell configureWithTitle:track.displayTitle
                  titleColor:[UIColor labelColor]
                      artist:(showError ? errorText : (track.displayArtist ?: @""))
                 artistColor:(showError ? [UIColor systemRedColor]
                                        : [UIColor secondaryLabelColor])
                    fileInfo:(showsInfo ? track.metadata.fileInfoLine : nil)
                   tempoInfo:(showsInfo ? [self tempoInfoLineForTrack:track] : nil)
                         art:[self artworkForPageAtIndex:index]];
    [self applyPlayOrderToCell:cell atIndex:index];
    [cell setOutputRouteKind:_playback.outputRouteKind
                  deviceName:_playback.outputRouteName];
    // The pad follows the setting, which the Playback screen's write carries
    // here through the display notification.
    [cell setFXPadShown:AppSettings.sharedInstance.audioFXEnabled];
    [cell setShuffleRepeatShown:AppSettings.sharedInstance.showShuffleRepeat];
}

// The mac's second info line: the tempo — the tag, or the analysis the
// waveform load ran — and the key. Tagged only, in Camelot, the mac's default
// notation: key analysis and the notation setting are macOS-only.
- (NSString *)tempoInfoLineForTrack:(AudioTrack *)track {
    return [[Formatters sharedInstance] tempoLineWithBPM:track.bpm
                                                 keyText:VibeMusicalKeyCamelotName(track.key)];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    TrackPageCell *cell = [collectionView
            dequeueReusableCellWithReuseIdentifier:TrackPageCell.reuseIdentifier
                                      forIndexPath:indexPath];
    [self configurePage:cell atIndex:(NSUInteger)indexPath.item];
    cell.transportView.alpha = [self chromeAlpha];
    cell.routeView.alpha = [self chromeAlpha];
    cell.actionBar.alpha = [self chromeAlpha];
    cell.fxPadView.alpha = [self chromeAlpha];
    return cell;
}

#pragma mark - Layout and size transitions

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Only on a real size change: this runs on every root layout pass, and
    // an invalidation re-prepares the whole layout.
    CGSize size = self.view.bounds.size;
    if (CGSizeEqualToSize(size, _lastLayoutSize)) {
        return;
    }
    _lastLayoutSize = size;
    _pagesLayout.itemSize = size;
    VibeSignpostCount(pager_invalidate);
    [_pagesLayout invalidateLayout];
    if (!_pagesView.isDragging && !_pagesView.isDecelerating) {
        [self scrollToCurrentPageAnimated:NO];
    }
    [self refreshWaveformWindow];
}

// Re-pages alongside the transition. The in-flight flag keeps
// commitVisiblePage from rounding a mid-resize offset to a neighbor, which
// would switch tracks.
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    _windowResizeInFlight = YES;
    // Before invalidation, while the collection view still has the old bounds.
    _pagesLayout.itemSize = size;
    // Every scrubber's bake is down for the transition, so deliveries and the
    // display link would each re-composite the live tree.
    [self applyFrameBudgetHold];
    // The window outlives the animation, to catch the scrubbers' re-bake
    // after the last layout pass.
    VibeWorkTallyBegin("rotation");
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        VibeSignpostCount(pager_invalidate);
        [self->_pagesLayout invalidateLayout];
        [self scrollToCurrentPageAnimated:NO];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        self->_windowResizeInFlight = NO;
        self->_pagesLayout.itemSize = self->_pagesView.bounds.size;
        [self scrollToCurrentPageAnimated:NO];
        // A request the hold DROPPED is never replayed, so ask again; a no-op
        // when this page is already the target.
        [self applyFrameBudgetHold];
        [self requestWaveformForIndex:self->_playlist.currentIndex];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VibeWorkTallyEnd();
        });
    }];
}

- (void)scrollToCurrentPageAnimated:(BOOL)animated {
    CGFloat width = _windowResizeInFlight
            ? _pagesLayout.itemSize.width
            : _pagesView.bounds.size.width;
    if (width <= 0 || _playlist.count == 0) {
        [self holdForProgrammaticPagerScrolling:NO];
        return;
    }
    CGPoint target = CGPointMake(width * (CGFloat)_playlist.currentIndex, 0);
    BOOL neighbor = fabs(_pagesView.contentOffset.x - target.x) <= width * 1.5;
    BOOL animateOnScreen = animated && neighbor && self.isPresented
            && !UIAccessibilityIsReduceMotionEnabled();
    if (!CGPointEqualToPoint(_pagesView.contentOffset, target)) {
        [self holdForProgrammaticPagerScrolling:animateOnScreen];
        [_pagesView setContentOffset:target animated:animateOnScreen];
    }
    else {
        [self holdForProgrammaticPagerScrolling:NO];
    }
}

// The page's own index, so the last page arrives dimmed; under Repeat All
// nothing is last, and under shuffle only the current page knows its next.
- (void)applyPlayOrderToCell:(TrackPageCell *)cell atIndex:(NSUInteger)index {
    BOOL nextEnabled = index == _playlist.currentIndex ? _playlist.hasNextTrack
            : (index + 1 < _playlist.count || _playlist.repeatMode == VibeRepeatModeAll);
    [cell setNextEnabled:nextEnabled];
    [cell setShuffleEnabled:_playlist.shuffleEnabled repeatMode:_playlist.repeatMode];
}

- (void)applyPlayOrderToVisiblePages {
    for (TrackPageCell *cell in _pagesView.visibleCells) {
        NSIndexPath *path = [_pagesView indexPathForCell:cell];
        if (path) {
            [self applyPlayOrderToCell:cell atIndex:(NSUInteger)path.item];
        }
    }
}

// In place only; willDisplayCell: re-configures off-screen cells.
- (void)refreshPageAtIndex:(NSUInteger)index {
    if (index >= _playlist.count) {
        return;
    }
    TrackPageCell *cell = [self cellAtIndex:index];
    if (cell) {
        [self configurePage:cell atIndex:index];
    }
}

#pragma mark - The art window

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

// A commit or a replacement can land mid-decode: the page must still be in the
// window AND hold the track the load was started for.
- (BOOL)artStillWantedForTrack:(AudioTrack *)track atIndex:(NSUInteger)index {
    return NSLocationInRange(index, [self artWindow]) &&
           [_playlist trackAtIndex:index] == track;
}

// Metadata first, on the PRIORITY lane: the art dispatch hangs off the
// metadata object, which behind a cloud folder's sweep can be minutes away.
- (void)prefetchPageAtIndex:(NSUInteger)index {
    AudioTrack *track = [_playlist trackAtIndex:index];
    if (!track) {
        return;
    }
    [_playback loadMetadataNowForTrack:track];
    AudioTrackMetadata *metadata = track.metadata;
    __weak PlayerViewController *weakSelf = self;
    [metadata loadArtIfNeededStillWanted:^BOOL{
        // A dead controller answers "not wanted", which demotes the decode.
        return track.metadata == metadata &&
                [weakSelf artStillWantedForTrack:track atIndex:index];
    } completion:^(VibeImage *loaded) {
        PlayerViewController *self = weakSelf;
        if (!self || !loaded) {
            return;
        }
        [self->_artHeldPages addIndex:index];
        [self refreshPageAtIndex:index];
        [self refreshWaveformWindow];
        if ([self->_playlist isCurrentTrack:track]) {
            [self->_playback publishNowPlaying];
        }
    }];
}

- (void)refreshArtWindow {
    NSRange window = [self artWindow];
    for (NSUInteger index = window.location; index < NSMaxRange(window); index++) {
        [self prefetchPageAtIndex:index];
    }
    [self releaseArtBeyondBudget];
    [self refreshWaveformWindow];
}

// Zero for a stale entry, which then drops out of the set.
- (NSUInteger)artBytesAtIndex:(NSUInteger)index {
    CGImageRef image = [_playlist trackAtIndex:index].cachedArt.CGImage;
    return image ? CGImageGetBytesPerRow(image) * CGImageGetHeight(image) : 0;
}

// Furthest page first: in a pager, distance is recency.
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
            [_artHeldPages removeIndex:index];
            continue;
        }
        // A page in the window or with a live cell keeps its art: its image
        // view pins the bitmap anyway, and releasing it risks the placeholder
        // in full view. A later pass collects it.
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

// Photos semantics: the settled page becomes the current track.
- (void)commitVisiblePage {
    CGFloat width = _pagesView.bounds.size.width;
    // Minimized, a replacement settles a scroll nobody made.
    if (width <= 0 || _playlist.count == 0 || _windowResizeInFlight || !self.isPresented) {
        return;
    }
    NSUInteger page = (NSUInteger)MAX(0.0, round(_pagesView.contentOffset.x / width));
    page = MIN(page, _playlist.count - 1);
    if (page != _playlist.currentIndex) {
        [_playback selectTrackAtIndex:page];
    }
    else if (_waveformCoordinator.targetIndex != page) {
        // Retry a request dropped during the hold.
        [self requestWaveformForIndex:page];
    }
}

#pragma mark - The frame-budget hold

// DERIVED from a swipe, a visible programmatic scroll and a size transition,
// owned by none: while on, the coordinator holds deliveries and requests and
// the display link pauses.
- (void)applyFrameBudgetHold {
    BOOL held = _pagerScrolling || _pagerProgrammaticScrolling || _windowResizeInFlight;
    _waveformCoordinator.held = held;
    [self updateScrollLinkState];
    if (!held) {
        [self refreshWaveformWindow];
    }
}

- (void)holdForPagerScrolling:(BOOL)scrolling {
    if (_pagerScrolling == scrolling) {
        return;
    }
    _pagerScrolling = scrolling;
    [self applyFrameBudgetHold];
}

// TRAP: the one hold with no guaranteed end callback:
// scrollViewDidEndScrollingAnimation: never arrives for a superseded animation.
// Stranded, it freezes waveform deliveries AND the display link until the next
// swipe, so every take arms a generation-tagged deadline.
- (void)holdForProgrammaticPagerScrolling:(BOOL)scrolling {
    BOOL changed = _pagerProgrammaticScrolling != scrolling;
    _pagerProgrammaticScrolling = scrolling;
    // A fresh deadline per request, or an old one releases mid-retarget.
    uint64_t generation = ++_pagerProgrammaticScrollGeneration;
    if (changed) {
        [self applyFrameBudgetHold];
    }
    if (!scrolling) {
        return;
    }
    __weak PlayerViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kProgrammaticScrollHoldCeilingSeconds * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
        PlayerViewController *strongSelf = weakSelf;
        if (strongSelf && generation == strongSelf->_pagerProgrammaticScrollGeneration) {
            [strongSelf holdForProgrammaticPagerScrolling:NO];
            // The end callback's reissue, since the hold dropped requests.
            if (strongSelf.isPresented) {
                [strongSelf requestWaveformForIndex:strongSelf->_playlist.currentIndex];
            }
        }
    });
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    // User hold first, so pending deliveries never flash through between.
    [self holdForPagerScrolling:YES];
    [self holdForProgrammaticPagerScrolling:NO];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    // Before the commit, so the settled page's request gets through.
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

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    CGFloat width = _pagesView.bounds.size.width;
    CGFloat targetX = width * (CGFloat)_playlist.currentIndex;
    if (self.isPresented && fabs(_pagesView.contentOffset.x - targetX) > 0.5) {
        return;   // a superseded animation
    }
    [self holdForProgrammaticPagerScrolling:NO];
    if (self.isPresented) {
        [self requestWaveformForIndex:_playlist.currentIndex];
    }
}

@end
