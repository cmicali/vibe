//
//  PlayerViewController.m
//  Vibe (iOS)
//

#import "PlayerViewController.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Recovery.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioSessionController.h"
#import "FolderSession.h"
#import "Playlist.h"
#import "NowPlayingController.h"
#import "SearchViewController.h"
#import "TrackListViewController.h"
#import "TrackPageCell.h"
#import "UIUpdateTimer.h"
#import "Formatters.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"
#if DEBUG
// The Debug category's state dump only.
#import "AppSettings.h"
#import "MusicalKey.h"
#endif

static const NSUInteger kUIUpdateHz = 3;

// The waveform strip's geometry against the safe-area bottom, shared by the
// in-cell attachment and the transport buttons anchored above it on the
// overlay: the strip reparents between pages, so nothing may constrain
// across that boundary.
static const CGFloat kWaveformHeight = 180;
static const CGFloat kWaveformBottomInset = 190;   // waveform.bottom above safe.bottom

@interface PlayerViewController () <AudioPlayerDelegate, PlaylistObserver,
        AudioTrackMetadataCacheDelegate, AudioWaveformCacheDelegate,
        WaveformScrubberViewDelegate, NowPlayingControllerDelegate,
        AudioSessionControllerDelegate, FolderSessionDelegate,
        UIGestureRecognizerDelegate, UICollectionViewDataSource,
        UICollectionViewDelegateFlowLayout>
@end

@implementation PlayerViewController {
    AudioPlayer             *_player;
    Playlist                *_playlist;
    AudioTrackMetadataCache *_metadataCache;
    AudioWaveformCache      *_waveformCache;
    NowPlayingController    *_nowPlaying;
    AudioSessionController  *_audioSession;
    FolderSession           *_folderSession;
    UIUpdateTimer           *_updateTimer;
    // Drives the scrolling waveform at display rate while playing in the
    // foreground; the 3 Hz timer is far too coarse for a moving waveform.
    CADisplayLink           *_scrollLink;
    BOOL                    _foreground;
    // seekToPosition: fades down before rescheduling, so position briefly
    // reports the pre-seek value; holding the target until didFinishSeeking:
    // keeps the waveform from snapping back for those frames.
    float                   _pendingSeekProgress;
    BOOL                    _seekInFlight;

    // The track pager, Photos-style: one full-screen cell per track (blurred
    // art + header), interactively draggable to the neighbors. The chrome —
    // waveform, transport, time, bottom bar — overlays it and never scrolls.
    // The screen is forced dark so text and the waveform read over any art.
    UICollectionView        *_pagesView;
    UICollectionViewFlowLayout *_pagesLayout;
    UILabel                 *_emptyHintLabel;
    // The waveform and its time labels travel together as a strip that
    // reparents into the current track's page cell, so a page drag carries
    // the waveform with it. There is only one live waveform, so an outgoing
    // page keeps it until the cell leaves the screen, and the strip parks
    // detached between homes.
    UIView                  *_waveformStrip;
    NSArray<NSLayoutConstraint *> *_stripOuterConstraints;
    WaveformScrubberView    *_waveformView;
    UILabel                 *_elapsedLabel;
    UILabel                 *_remainingLabel;
    UIButton                *_playPauseButton;
    UIButton                *_nextButton;
    UIButton                *_searchBarButton;  // Messages-style glass search bar
    UIButton                *_folderButton;     // the compose-position circle
    UITapGestureRecognizer  *_emptyStateTap;

    TrackListViewController *_trackListController;

    // An inline playback error, shown on the artist line until the next track
    // event, exactly like the mac header.
    NSString                *_errorText;
    // A restored track is parked: header, waveform, and metadata are loaded,
    // but nothing plays until the user asks.
    BOOL                    _parked;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // Forced dark, like the Apple Music and SoundCloud player screens: every
    // label and the waveform must read over arbitrary blurred art.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self buildUI];

    _playlist = [[Playlist alloc] init];
    _playlist.observer = self;
    _metadataCache = [[AudioTrackMetadataCache alloc] init];
    _metadataCache.delegate = self;
    _waveformCache = [[AudioWaveformCache alloc] init];
    _waveformCache.delegate = self;
    _audioSession = [[AudioSessionController alloc] init];
    _audioSession.delegate = self;
    _folderSession = [[FolderSession alloc] init];
    _folderSession.delegate = self;
    _nowPlaying = [[NowPlayingController alloc] initWithDelegate:self];
    _player = [[AudioPlayer alloc] initWithDeviceUID:@"" name:@"" delegate:self];

    __weak PlayerViewController *weakSelf = self;
    _updateTimer = [[UIUpdateTimer alloc] initWithHz:kUIUpdateHz handler:^{
        [weakSelf updatePlaybackUI];
    }];
    _updateTimer.windowVisible = YES;

    _foreground = YES;
    _scrollLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(scrollTick:)];
    // ~1pt/frame of motion gains nothing at 120 Hz; spare ProMotion the work.
    _scrollLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    _scrollLink.paused = YES;
    [_scrollLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    // In the background the system extrapolates position from the last Now
    // Playing publish, so the 3 Hz tick is pure waste there — the same rule
    // as the mac window's occlusion gate.
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(sceneDidEnterBackground)
                   name:UISceneDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(sceneWillEnterForeground)
                   name:UISceneWillEnterForegroundNotification object:nil];

    if (![_folderSession restorePersistedFolder]) {
        [self showEmptyState];
    }
}

- (void)sceneDidEnterBackground {
    _updateTimer.windowVisible = NO;
    _foreground = NO;
    [self updateScrollLinkState];
}

- (void)sceneWillEnterForeground {
    _updateTimer.windowVisible = YES;
    _foreground = YES;
    [self updateScrollLinkState];
    [self updatePlaybackUI];
}

// CADisplayLink retains its target; without this the controller would leak.
// The root controller never deallocs in practice, but keep it correct.
- (void)dealloc {
    [_scrollLink invalidate];
}

#pragma mark - UI construction

- (void)buildUI {
    UIView *root = self.view;

    _pagesLayout = [[UICollectionViewFlowLayout alloc] init];
    _pagesLayout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    _pagesLayout.minimumLineSpacing = 0;
    _pagesLayout.minimumInteritemSpacing = 0;
    _pagesView = [[UICollectionView alloc] initWithFrame:CGRectZero
                                    collectionViewLayout:_pagesLayout];
    _pagesView.pagingEnabled = YES;
    _pagesView.showsHorizontalScrollIndicator = NO;
    _pagesView.allowsSelection = NO;
    _pagesView.backgroundColor = [UIColor clearColor];
    // Pages must be exactly screen-sized; safe-area adjustment would shrink
    // the content and break the paging math.
    _pagesView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _pagesView.dataSource = self;
    _pagesView.delegate = self;
    [_pagesView registerClass:TrackPageCell.class
        forCellWithReuseIdentifier:TrackPageCell.reuseIdentifier];
    _pagesView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_pagesView];

    _emptyHintLabel = [[UILabel alloc] init];
    _emptyHintLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    _emptyHintLabel.textColor = [UIColor secondaryLabelColor];
    _emptyHintLabel.textAlignment = NSTextAlignmentCenter;
    _emptyHintLabel.numberOfLines = 0;
    _emptyHintLabel.text = STR_LABEL_OPEN_HINT_IOS;
    _emptyHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_emptyHintLabel];

    _waveformStrip = [[UIView alloc] init];
    _waveformStrip.translatesAutoresizingMaskIntoConstraints = NO;

    _waveformView = [[WaveformScrubberView alloc] initWithFrame:CGRectZero];
    _waveformView.delegate = self;
    _waveformView.translatesAutoresizingMaskIntoConstraints = NO;
    [_waveformStrip addSubview:_waveformView];

    _elapsedLabel = [self makeTimeLabel];
    _remainingLabel = [self makeTimeLabel];
    _remainingLabel.textAlignment = NSTextAlignmentRight;
    [_waveformStrip addSubview:_elapsedLabel];
    [_waveformStrip addSubview:_remainingLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_waveformView.topAnchor constraintEqualToAnchor:_waveformStrip.topAnchor],
        [_waveformView.leadingAnchor constraintEqualToAnchor:_waveformStrip.leadingAnchor],
        [_waveformView.trailingAnchor constraintEqualToAnchor:_waveformStrip.trailingAnchor],
        [_waveformView.heightAnchor constraintEqualToConstant:kWaveformHeight],
        [_elapsedLabel.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor constant:6],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:_waveformStrip.leadingAnchor constant:16],
        [_remainingLabel.topAnchor constraintEqualToAnchor:_elapsedLabel.topAnchor],
        [_remainingLabel.trailingAnchor constraintEqualToAnchor:_waveformStrip.trailingAnchor constant:-16],
        [_waveformStrip.bottomAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor],
    ]];
    [self attachWaveformStripToView:root];

    _playPauseButton = [self makeTransportButton:@"play.fill" pointSize:44
                                          action:@selector(playPauseTapped)];
    _playPauseButton.accessibilityLabel = STR_TRANSPORT_PLAY;
    _nextButton = [self makeTransportButton:@"forward.end.fill" pointSize:26
                                     action:@selector(nextTapped)];
    _nextButton.accessibilityLabel = STR_TRANSPORT_NEXT;

    [root addSubview:_playPauseButton];
    [root addSubview:_nextButton];

    // The Messages-style bottom bar: a wide glass search field, and the
    // folder button in the compose position beside it.
    UIButtonConfiguration *searchConfig = [UIButtonConfiguration glassButtonConfiguration];
    searchConfig.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    searchConfig.image = [UIImage systemImageNamed:@"magnifyingglass"];
    searchConfig.title = STR_LABEL_SEARCH;
    searchConfig.imagePadding = 8;
    searchConfig.baseForegroundColor = [UIColor secondaryLabelColor];
    searchConfig.contentInsets = NSDirectionalEdgeInsetsMake(14, 18, 14, 18);
    _searchBarButton = [UIButton buttonWithConfiguration:searchConfig primaryAction:nil];
    _searchBarButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    _searchBarButton.accessibilityLabel = STR_LABEL_SEARCH;
    [_searchBarButton addTarget:self action:@selector(searchTapped)
               forControlEvents:UIControlEventTouchUpInside];
    _searchBarButton.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_searchBarButton];

    UIButtonConfiguration *folderConfig = [UIButtonConfiguration glassButtonConfiguration];
    folderConfig.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    folderConfig.image = [UIImage systemImageNamed:@"list.bullet"];
    folderConfig.baseForegroundColor = [UIColor labelColor];
    _folderButton = [UIButton buttonWithConfiguration:folderConfig primaryAction:nil];
    _folderButton.accessibilityLabel = STR_A11Y_TOGGLE_PLAYLIST;
    [_folderButton addTarget:self action:@selector(playlistTapped)
            forControlEvents:UIControlEventTouchUpInside];
    _folderButton.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_folderButton];

    // Tap anywhere (off the waveform and the controls): choose a folder when
    // empty, otherwise toggle play/pause — the transport hides while playing,
    // so the tap IS the pause control.
    _emptyStateTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                             action:@selector(screenTapped)];
    _emptyStateTap.delegate = self;
    [root addGestureRecognizer:_emptyStateTap];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        [_pagesView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_pagesView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_pagesView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_pagesView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],

        [_emptyHintLabel.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_emptyHintLabel.centerYAnchor constraintEqualToAnchor:root.centerYAnchor],
        [_emptyHintLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [_emptyHintLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],

        // Play/pause on the screen's center line, next to its right, sitting
        // just above where the waveform strip rides in the pages. Anchored to
        // the root, not the strip — the strip reparents between cells.
        [_playPauseButton.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_playPauseButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                constant:-(kWaveformBottomInset + kWaveformHeight + 16)],
        [_nextButton.leadingAnchor constraintEqualToAnchor:_playPauseButton.trailingAnchor constant:40],
        [_nextButton.centerYAnchor constraintEqualToAnchor:_playPauseButton.centerYAnchor],

        [_searchBarButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_searchBarButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4],
        [_searchBarButton.heightAnchor constraintEqualToConstant:52],
        [_folderButton.leadingAnchor constraintEqualToAnchor:_searchBarButton.trailingAnchor constant:12],
        [_folderButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_folderButton.centerYAnchor constraintEqualToAnchor:_searchBarButton.centerYAnchor],
        [_folderButton.widthAnchor constraintEqualToConstant:52],
        [_folderButton.heightAnchor constraintEqualToConstant:52],
    ]];
}

- (UILabel *)makeTimeLabel {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = STR_LABEL_TIME_UNKNOWN;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (UIButton *)makeTransportButton:(NSString *)symbol pointSize:(CGFloat)pointSize
                           action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                        weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config]
            forState:UIControlStateNormal];
    button.tintColor = [UIColor labelColor];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:64].active = YES;
    [button.heightAnchor constraintEqualToConstant:72].active = YES;
    return button;
}

#pragma mark - Gestures

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    // The waveform owns horizontal drags and taps for scrubbing, and the
    // controls own their touches; the screen tap applies everywhere else.
    // Membership, not frames: the strip lives inside whichever page cell is
    // current, so its frame is in another view's coordinates.
    if ([touch.view isDescendantOfView:_waveformStrip]) {
        return NO;
    }
    for (UIView *view = touch.view; view && view != self.view; view = view.superview) {
        if ([view isKindOfClass:[UIControl class]]) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - Waveform strip attachment

// Moves the strip into a new home — the current track's page cell, or the
// root for the empty state — pinning the waveform's bottom to the home's
// safe-area bottom so the geometry is identical everywhere. Cells are
// screen-sized, so their safe area is the screen's.
- (void)attachWaveformStripToView:(UIView *)parent {
    if (_waveformStrip.superview == parent) {
        return;
    }
    if (_stripOuterConstraints) {
        [NSLayoutConstraint deactivateConstraints:_stripOuterConstraints];
    }
    [_waveformStrip removeFromSuperview];
    [parent addSubview:_waveformStrip];
    _stripOuterConstraints = @[
        [_waveformStrip.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor],
        [_waveformStrip.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor],
        [_waveformView.bottomAnchor constraintEqualToAnchor:parent.safeAreaLayoutGuide.bottomAnchor
                                                   constant:-kWaveformBottomInset],
    ];
    [NSLayoutConstraint activateConstraints:_stripOuterConstraints];
}

// Between homes — the outgoing page left the screen and the incoming cell
// does not exist yet. A parked strip renders nowhere but keeps all state.
- (void)parkWaveformStrip {
    if (_stripOuterConstraints) {
        [NSLayoutConstraint deactivateConstraints:_stripOuterConstraints];
        _stripOuterConstraints = nil;
    }
    [_waveformStrip removeFromSuperview];
}

- (void)attachWaveformStripToCurrentPage {
    if (_playlist.count == 0) {
        [self attachWaveformStripToView:self.view];
        return;
    }
    UICollectionViewCell *cell = [_pagesView cellForItemAtIndexPath:
            [NSIndexPath indexPathForItem:(NSInteger)_playlist.currentIndex inSection:0]];
    if (cell) {
        [self attachWaveformStripToView:cell.contentView];
    }
    // No cell yet: collectionView:willDisplayCell: attaches when it appears.
}

#pragma mark - Track pager

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)_playlist.count;
}

- (void)collectionView:(UICollectionView *)collectionView
       willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    if ((NSUInteger)indexPath.item == _playlist.currentIndex) {
        [self attachWaveformStripToView:cell.contentView];
    }
}

- (void)collectionView:(UICollectionView *)collectionView
  didEndDisplayingCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    // The strip must never ride a cell into the reuse pool — it would
    // resurface inside some other track's page.
    if ([_waveformStrip isDescendantOfView:cell]) {
        [self parkWaveformStrip];
    }
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    TrackPageCell *cell = [collectionView
            dequeueReusableCellWithReuseIdentifier:TrackPageCell.reuseIdentifier
                                      forIndexPath:indexPath];
    AudioTrack *track = [_playlist trackAtIndex:(NSUInteger)indexPath.item];
    BOOL isCurrent = (NSUInteger)indexPath.item == _playlist.currentIndex;
    BOOL showError = isCurrent && _errorText;
    // Neighbors show their cached thumbnail — under the blur the 128px
    // thumbnail and the full decode are indistinguishable, and only the
    // current track ever decodes full art.
    [cell configureWithTitle:(track.hasArtistAndTitle ? track.title : track.singleLineTitle)
                  titleColor:[UIColor labelColor]
                      artist:(showError ? _errorText
                                        : (track.hasArtistAndTitle ? track.artist : @""))
                 artistColor:(showError ? [UIColor systemRedColor]
                                        : [UIColor secondaryLabelColor])
                    fileInfo:[self fileInfoTextForTrack:track]
                         art:(track.albumArt ?: track.thumbnailAlbumArt)];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return _pagesView.bounds.size;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Page size follows the view, and the offset must stay page-aligned
    // through the first layout after a restore.
    [_pagesLayout invalidateLayout];
    if (!_pagesView.isDragging && !_pagesView.isDecelerating) {
        [self scrollToCurrentPageAnimated:NO];
    }
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

- (void)refreshPageAtIndex:(NSUInteger)index {
    if (index < _playlist.count) {
        [_pagesView reloadItemsAtIndexPaths:
                @[[NSIndexPath indexPathForItem:(NSInteger)index inSection:0]]];
    }
}

// The grab-and-pull commit, Photos semantics: whatever page the drag settles
// on becomes the current track; pulling back to the same page changes
// nothing.
- (void)commitVisiblePage {
    CGFloat width = _pagesView.bounds.size.width;
    if (width <= 0 || _playlist.count == 0) {
        return;
    }
    NSUInteger page = (NSUInteger)MAX(0.0, round(_pagesView.contentOffset.x / width));
    page = MIN(page, _playlist.count - 1);
    if (page != _playlist.currentIndex) {
        _playlist.currentIndex = page;
        [self playCurrentTrack];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self commitVisiblePage];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self commitVisiblePage];
    }
}

#pragma mark - Header rendering

- (void)showEmptyState {
    _emptyHintLabel.text = STR_LABEL_OPEN_HINT_IOS;
    _emptyHintLabel.hidden = NO;
    [self attachWaveformStripToView:self.view];
    _elapsedLabel.text = STR_LABEL_TIME_UNKNOWN;
    _remainingLabel.text = STR_LABEL_TIME_UNKNOWN;
    [_waveformView showEmptyPlaceholder];
    [self updatePlayButton];
}

// The pager owns the header and art; rendering the current track means
// refreshing its page and making sure the waveform strip rides in it.
- (void)renderHeaderForTrack:(AudioTrack *)track {
    _emptyHintLabel.hidden = YES;
    [self refreshPageAtIndex:_playlist.currentIndex];
    [self attachWaveformStripToCurrentPage];
}

// The mac codec line's composition: each part appended only when present, so
// the label never shows "(null) kbps" or "0.0 kHz".
- (NSString *)fileInfoTextForTrack:(AudioTrack *)track {
    if (!track.metadata.fileType) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:track.metadata.fileType];
    if (!track.metadata.isLossless && track.metadata.bitrate) {
        [parts addObject:[NSString stringWithFormat:STR_LABEL_BITRATE,
                [[Formatters sharedInstance] decimalString:track.metadata.bitrate.doubleValue
                                            fractionDigits:0]]];
    }
    if (track.metadata.sampleRate) {
        [parts addObject:[NSString stringWithFormat:STR_LABEL_SAMPLE_RATE,
                [[Formatters sharedInstance] decimalString:track.metadata.sampleRate.doubleValue / 1000
                                            fractionDigits:1]]];
    }
    return [parts componentsJoinedByString:VibeNotLocalized(@" | ")];
}

- (void)updatePlayButton {
    BOOL playing = _player.isPlaying;
    NSString *symbol = playing ? @"pause.fill" : @"play.fill";
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:44
                                                        weight:UIImageSymbolWeightMedium];
    [_playPauseButton setImage:[UIImage systemImageNamed:symbol withConfiguration:config]
                      forState:UIControlStateNormal];
    _playPauseButton.accessibilityLabel = playing ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;
    [self updateChrome];
}

// Playing hides the transport — a screen tap pauses — and pausing (parked,
// stopped, and empty included) brings the buttons back. The art stays
// blurred in every state.
- (void)updateChrome {
    CGFloat buttonAlpha = _player.isPlaying ? 0 : 1;
    if (_playPauseButton.alpha == buttonAlpha) {
        return;
    }
    [UIView animateWithDuration:0.3 animations:^{
        self->_playPauseButton.alpha = buttonAlpha;
        self->_nextButton.alpha = buttonAlpha;
    }];
}

- (void)updateScrollLinkState {
    _scrollLink.paused = !(_player.isPlaying && _foreground);
}

- (void)scrollTick:(CADisplayLink *)link {
    if (_waveformView.isScrubbing) {
        return;
    }
    if (_seekInFlight) {
        _waveformView.progress = _pendingSeekProgress;
        return;
    }
    NSTimeInterval duration = _player.duration;  // non-blocking, like position
    if (duration > 0) {
        _waveformView.progress = _player.position / duration;
    }
}

- (void)updatePlaybackUI {
    NSTimeInterval position = _player.position;
    NSTimeInterval duration = _player.duration;
    if (duration > 0) {
        Formatters *formatters = [Formatters sharedInstance];
        _elapsedLabel.text = [formatters durationStringFromTimeInterval:position];
        _remainingLabel.text = [formatters durationStringFromTimeInterval:MAX(0, duration - position)];
        // The display link owns the waveform while playing; this 3 Hz write
        // is the only one while paused or parked, and they agree otherwise.
        if (!_waveformView.isScrubbing && !_seekInFlight) {
            _waveformView.progress = position / duration;
        }
    }
    else {
        _elapsedLabel.text = STR_LABEL_TIME_UNKNOWN;
        _remainingLabel.text = STR_LABEL_TIME_UNKNOWN;
    }
    [self publishNowPlaying];
}

- (void)publishNowPlaying {
    NowPlayingPlaybackState state = NowPlayingPlaybackStateStopped;
    if (_player.isPlaying) {
        state = NowPlayingPlaybackStatePlaying;  // Loading included: play is imminent
    }
    else if (_player.isPaused) {
        state = NowPlayingPlaybackStatePaused;
    }
    [_nowPlaying updateWithTrack:(_parked || _player.currentTrack) ? _playlist.currentTrack : nil
                        position:_player.position
                        duration:_player.duration
                           state:state
                            rate:1.0
                         hasNext:_playlist.hasNextTrack
                     hasPrevious:_playlist.hasPreviousTrack];
}

#pragma mark - Playback

- (void)playCurrentTrack {
    AudioTrack *track = _playlist.currentTrack;
    if (!track) {
        return;
    }
    _errorText = nil;
    _parked = NO;
    _seekInFlight = NO;
    [_audioSession activate];
    [self renderHeaderForTrack:track];
    [self scrollToCurrentPageAnimated:YES];
    [_waveformView prepareForWaveformLoad];
    [_waveformCache cancelLoad];
    [_waveformCache loadWaveformForTrack:track];
    [_metadataCache loadMetadataNow:track];
    [_player play:track];
    [self updatePlayButton];
}

// Parks a restored track: everything renders, nothing plays.
- (void)parkCurrentTrack {
    AudioTrack *track = _playlist.currentTrack;
    if (!track) {
        return;
    }
    _parked = YES;
    _seekInFlight = NO;
    [self renderHeaderForTrack:track];
    [self scrollToCurrentPageAnimated:NO];
    [_waveformView prepareForWaveformLoad];
    [_waveformCache cancelLoad];
    [_waveformCache loadWaveformForTrack:track];
    [_metadataCache loadMetadataNow:track];
    [self updatePlayButton];
}

#pragma mark - Transport actions

- (void)playlistTapped {
    if (_playlist.count == 0) {
        [_folderSession presentPickerFromViewController:self];
        return;
    }
    [self presentTrackList];
}

- (void)playPauseTapped {
    if (_player.isPlaying) {
        [_player playPause];
    }
    else if (_player.isPaused) {
        [_audioSession activate];
        [_player playPause];
    }
    else {
        // Stopped: a parked restore, a finished playlist, or a failed track.
        [self playCurrentTrack];
    }
}

- (void)nextTapped {
    if ([_playlist next]) {
        [self playCurrentTrack];
    }
}

- (void)screenTapped {
    if (_playlist.count == 0) {
        [_folderSession presentPickerFromViewController:self];
        return;
    }
    [self playPauseTapped];
}

- (void)searchTapped {
    if (_playlist.count == 0) {
        [_folderSession presentPickerFromViewController:self];
        return;
    }
    SearchViewController *search = [[SearchViewController alloc] initWithPlaylist:_playlist];
    __weak PlayerViewController *weakSelf = self;
    search.onSelectTrack = ^(NSUInteger index) {
        PlayerViewController *self = weakSelf;
        if (self) {
            self->_playlist.currentIndex = index;
            [self playCurrentTrack];
        }
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:search];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)presentTrackList {
    TrackListViewController *list = [[TrackListViewController alloc] initWithPlaylist:_playlist];
    list.folderName = _folderSession.folderDisplayName;
    __weak PlayerViewController *weakSelf = self;
    list.onSelectTrack = ^(NSUInteger index) {
        PlayerViewController *self = weakSelf;
        if (self) {
            self->_playlist.currentIndex = index;
            [self playCurrentTrack];
        }
    };
    list.onChooseFolder = ^{
        PlayerViewController *self = weakSelf;
        if (self) {
            [self->_folderSession presentPickerFromViewController:self];
        }
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                      UISheetPresentationControllerDetent.largeDetent];
    _trackListController = list;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - FolderSessionDelegate

- (void)folderSession:(FolderSession *)session
        didOpenTracks:(NSArray<NSURL *> *)urls
            folderURL:(NSURL *)folderURL
             restored:(BOOL)restored {
    [_playlist replaceAllWithURLs:urls];
    [_pagesView reloadData];
    [_metadataCache cancelAll];
    [_metadataCache loadMetadata:_playlist.tracks];

    if (restored) {
        NSString *fileName = session.persistedTrackFileName;
        if (fileName) {
            NSArray<AudioTrack *> *tracks = _playlist.tracks;
            for (NSUInteger i = 0; i < tracks.count; i++) {
                if ([tracks[i].url.lastPathComponent isEqualToString:fileName]) {
                    _playlist.currentIndex = i;
                    break;
                }
            }
        }
        [self parkCurrentTrack];
    }
    else {
        [self playCurrentTrack];
    }
}

- (void)folderSessionDidOpenEmptyFolder:(FolderSession *)session {
    if (_playlist.count == 0) {
        [self showEmptyState];
        _emptyHintLabel.text = STR_ERROR_FOLDER_EMPTY;
    }
}

- (void)handleOpenURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    UIOpenURLContext *context = contexts.anyObject;
    if (context) {
        [_folderSession openExternalURL:context.URL openInPlace:context.options.openInPlace];
    }
}

#pragma mark - AudioPlayerDelegate

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer {
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    [_waveformView showLoadingIndicator];
    [self publishNowPlaying];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    _errorText = nil;
    [_waveformView hideLoadingIndicator];
    [self renderHeaderForTrack:track];
    // The dataless-placeholder retry: a cache miss skipped while the player's
    // own open was materializing the file parses now.
    [_metadataCache loadMetadataNow:track];
    NSUInteger nextIndex = _playlist.currentIndex + 1;
    [_player prefetchTrack:_playlist.hasNextTrack ? [_playlist trackAtIndex:nextIndex] : nil];
    _folderSession.persistedTrackFileName = track.url.lastPathComponent;
    // The landing can be parked — a pause verdict during the load, or the
    // media-reset re-park — in which case playback is idle, so the session is
    // released just as a pause releases it.
    BOOL playing = _player.isPlaying;
    _updateTimer.wanted = playing;
    [self updateScrollLinkState];
    if (!playing) {
        [_audioSession deactivateWhenIdle];
    }
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    _updateTimer.wanted = NO;
    [self updateScrollLinkState];
    [_audioSession deactivateWhenIdle];
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
    _updateTimer.wanted = YES;
    [self updateScrollLinkState];
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track {
    _seekInFlight = NO;
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track {
    if ([_playlist next]) {
        [self playCurrentTrack];
        return;
    }
    // End of playlist: park on the last track, ready to replay.
    _parked = YES;
    _updateTimer.wanted = NO;
    [self updateScrollLinkState];
    [_audioSession deactivateWhenIdle];
    _waveformView.progress = 0;
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOutputDevice:(NSInteger)newDeviceID {
    // macOS-only path; never sent on iOS.
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    NSURL *url = error.userInfo[kVibeAudioErrorTrackURLKey];
    AudioTrack *current = _playlist.currentTrack;
    if (url && current && ![url isEqual:current.url]) {
        return;  // a stale delivery racing a track change
    }
    _errorText = [self statusForPlayError:error];
    _seekInFlight = NO;
    [_waveformView hideLoadingIndicator];
    if (current) {
        [self renderHeaderForTrack:current];
    }
    _updateTimer.wanted = NO;
    [self updateScrollLinkState];
    [_audioSession deactivateWhenIdle];
    [self updatePlayButton];
    [self publishNowPlaying];
}

// The iOS twin of MainPlayerController's statusForPlayError: same codes,
// same strings.
- (NSString *)statusForPlayError:(NSError *)error {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain]) {
        switch ((VibeAudioErrorCode)error.code) {
            case VibeAudioErrorFileOpenTimedOut:   return STR_ERROR_LOAD_TIMEOUT;
            case VibeAudioErrorFileOpenFailed:     return STR_ERROR_OPEN_FAILED;
            case VibeAudioErrorEngineStartFailed:  return STR_ERROR_ENGINE_START_FAILED;
            case VibeAudioErrorDeviceUnavailable:  return STR_ERROR_DEVICE_UNAVAILABLE;
            default: break;
        }
    }
    return STR_ERROR_PLAYBACK_GENERIC;
}

#pragma mark - PlaylistObserver

- (void)playlistDidReplaceAllTracks:(Playlist *)playlist {
    [_trackListController reloadAll];
}

- (void)playlist:(Playlist *)playlist didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [_pagesView reloadData];
    [_trackListController reloadAll];
}

- (void)playlist:(Playlist *)playlist didReplaceTrackAtIndex:(NSUInteger)index {
    [_trackListController reloadTrackAtIndex:index];
}

- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex {
    [_trackListController reloadTrackAtIndex:previousIndex];
    [_trackListController reloadTrackAtIndex:playlist.currentIndex];
}

#pragma mark - AudioTrackMetadataCacheDelegate

- (void)didLoadMetadata:(AudioTrack *)track {
    NSInteger row = [_playlist getIndexForTrack:track];
    if (row >= 0) {
        [_trackListController reloadTrackAtIndex:(NSUInteger)row];
        [self refreshPageAtIndex:(NSUInteger)row];
    }
    if ([_playlist isCurrentTrack:track]) {
        [self publishNowPlaying];
    }
}

#pragma mark - AudioWaveformCacheDelegate

- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded {
    // No URL rides on this delivery; cancelLoad before every new load is the
    // race guard, per the cache's contract.
    [_waveformView showWaveform:waveform];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forURL:(NSURL *)url {
    AudioTrack *current = _playlist.currentTrack;
    if (current && [current.url isEqual:url]) {
        current.detectedBPM = bpm;
    }
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectKey:(NSInteger)key forURL:(NSURL *)url {
    AudioTrack *current = _playlist.currentTrack;
    if (current && [current.url isEqual:url]) {
        current.detectedKey = (VibeMusicalKey)key;
    }
}

#pragma mark - WaveformScrubberViewDelegate

- (void)waveformScrubberView:(WaveformScrubberView *)view didSeek:(float)percentage {
    NSTimeInterval duration = _player.duration;
    if (duration > 0) {
        _pendingSeekProgress = percentage;
        _seekInFlight = YES;
        [_player seekToPosition:duration * percentage];
    }
    else if (_parked) {
        [self playCurrentTrack];
    }
}

#pragma mark - NowPlayingControllerDelegate

- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {
    if (!_player.isPlaying) {
        [self playPauseTapped];
    }
}

- (void)nowPlayingControllerPause:(NowPlayingController *)controller {
    if (_player.isPlaying) {
        [_player playPause];
    }
}

- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller {
    [self playPauseTapped];
}

- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller {
    [self nextTapped];
}

- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller {
    if ([_playlist previous]) {
        [self playCurrentTrack];
    }
    else {
        [_player seekToPosition:0];
    }
}

- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position {
    [_player seekToPosition:position];
}

#pragma mark - AudioSessionControllerDelegate

- (BOOL)audioSessionShouldPause:(AudioSessionController *)controller {
    BOOL wasPlaying = _player.isPlaying;
    if (wasPlaying) {
        // While Loading this toggles the landing to parked instead: the
        // engine never starts against the interrupted session, and
        // shouldResume's isLoading branch flips it back.
        [_player playPause];
    }
    return wasPlaying;
}

- (void)audioSessionShouldResume:(AudioSessionController *)controller {
    if (_player.isPaused || _player.isLoading) {
        [_audioSession activate];
        [_player playPause];
    }
}

- (void)audioSessionEngineConfigurationChanged:(AudioSessionController *)controller {
    [_player recoverFromEngineConfigurationChange];
}

- (void)audioSessionMediaServicesWereReset:(AudioSessionController *)controller {
    // Every live audio object died with the media server. Capture the
    // playhead (the position getter serves its last-valid cache), rebuild the
    // engine, and re-park the current track there — paused, never blasting
    // back into playback after a server crash. The park's didStartPlaying:
    // settles the header, waveform and Now Playing card.
    AudioTrack *track = _playlist.currentTrack;
    NSTimeInterval position = _player.position;
    [_player reinitializeAfterMediaServicesReset];
    _seekInFlight = NO;
    _updateTimer.wanted = NO;
    [self updateScrollLinkState];
    if (track) {
        _parked = YES;
        [_player play:track atPosition:position startPaused:YES];
    }
    else {
        [self updatePlayButton];
        [self updatePlaybackUI];
    }
}

@end

#if DEBUG

#pragma mark - Debug command surface

// In the class's own file so the category reads the ivars directly; the verbs
// live in DebugCommands.m.

@implementation PlayerViewController (Debug)

- (NSDictionary *)debugStateDictionary {
    AudioTrack *track = _playlist.currentTrack;
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (AudioTrack *t in _playlist.tracks) {
        if (files.count == 100) {
            [files addObject:[NSString stringWithFormat:@"… %lu more",
                    (unsigned long)(_playlist.count - 100)]];
            break;
        }
        [files addObject:t.url.lastPathComponent ?: @""];
    }
    return @{
        @"player": @{
            @"state": _player.isPlaying ? @"playing" : (_player.isPaused ? @"paused" : @"stopped"),
            @"position": @(_player.position),
            @"duration": @(_player.duration),
            @"numChannels": @(_player.numChannels),
            @"silent": @([NSProcessInfo.processInfo.arguments containsObject:@"--silent"]),
            @"noAudioHw": @([NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"]),
        },
        @"currentTrack": track ? @{
            @"url": track.url.path ?: @"",
            @"title": track.title ?: @"",
            @"artist": track.artist ?: @"",
            @"bpm": @(track.bpm),
            // The resolved key (tag over analysis); empty strings when unknown.
            @"key": VibeMusicalKeyMusicalName(track.key),
            @"camelot": VibeMusicalKeyCamelotName(track.key),
        } : (id)NSNull.null,
        @"playlist": @{
            @"count": @(_playlist.count),
            @"currentIndex": @(_playlist.currentIndex),
            @"files": files,
        },
        @"ui": @{
            @"elapsed": _elapsedLabel.text ?: @"",
            @"remaining": _remainingLabel.text ?: @"",
            @"emptyHintShown": @(!_emptyHintLabel.isHidden),
            @"transportShown": @(_playPauseButton.alpha > 0),
            @"waveformProgress": @(_waveformView.progress),
            @"isScrubbing": @(_waveformView.isScrubbing),
            @"parked": @(_parked),
            @"foreground": @(_foreground),
            @"error": _errorText ?: @"",
        },
        @"settings": @{
            @"waveformStyle": Settings.waveformStyle ?: @"",
            @"analyzeBPM": @(Settings.analyzeBPM),
            @"analyzeKey": @(Settings.analyzeKey),
        },
    };
}

- (NSDictionary *)debugActionSummary {
    return @{
        @"ok": @YES,
        @"state": _player.isPlaying ? @"playing" : (_player.isPaused ? @"paused" : @"stopped"),
        @"index": @(_playlist.currentIndex),
        @"count": @(_playlist.count),
        @"position": @(_player.position),
        @"parked": @(_parked),
    };
}

- (void)debugPlayPause {
    [self playPauseTapped];
}

- (void)debugNext {
    [self nextTapped];
}

- (void)debugPrevious {
    if ([_playlist previous]) {
        [self playCurrentTrack];
    }
}

- (void)debugSeekToSeconds:(NSTimeInterval)seconds {
    NSTimeInterval duration = _player.duration;
    if (duration > 0) {
        float p = (float)MAX(0.0, MIN(1.0, seconds / duration));
        [self waveformScrubberView:_waveformView didSeek:p];
    }
}

- (void)debugOpenPath:(NSString *)path {
    [_folderSession openExternalURL:[NSURL fileURLWithPath:path] openInPlace:YES];
}

- (AudioTrackMetadataCache *)debugMetadataCache {
    return _metadataCache;
}

- (AudioWaveformCache *)debugWaveformCache {
    return _waveformCache;
}

@end

#endif
