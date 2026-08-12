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
#import "UIUpdateTimer.h"
#import "Formatters.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"

static const NSUInteger kUIUpdateHz = 3;

@interface PlayerViewController () <AudioPlayerDelegate, PlaylistObserver,
        AudioTrackMetadataCacheDelegate, AudioWaveformCacheDelegate,
        WaveformScrubberViewDelegate, NowPlayingControllerDelegate,
        AudioSessionControllerDelegate, FolderSessionDelegate,
        UIGestureRecognizerDelegate>
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

    // The blurred album art behind everything, Apple Music style: the art
    // aspect-fills the screen under a blur. The screen is forced dark so
    // text and the waveform read over any art.
    UIImageView             *_backgroundArtView;
    UIVisualEffectView      *_backgroundBlurView;

    UILabel                 *_artistLabel;      // small, top-left, above the title
    UILabel                 *_titleLabel;
    UILabel                 *_fileInfoLabel;    // the codec corner, top-right
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
}

- (void)sceneWillEnterForeground {
    _updateTimer.windowVisible = YES;
    [self updatePlaybackUI];
}

#pragma mark - UI construction

- (void)buildUI {
    UIView *root = self.view;

    _backgroundArtView = [[UIImageView alloc] init];
    _backgroundArtView.contentMode = UIViewContentModeScaleAspectFill;
    _backgroundArtView.clipsToBounds = YES;
    _backgroundArtView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_backgroundArtView];

    _backgroundBlurView = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    _backgroundBlurView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_backgroundBlurView];

    _artistLabel = [[UILabel alloc] init];
    _artistLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _artistLabel.textColor = [UIColor secondaryLabelColor];
    _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_artistLabel];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    _titleLabel.numberOfLines = 2;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_titleLabel];

    _fileInfoLabel = [[UILabel alloc] init];
    _fileInfoLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _fileInfoLabel.textColor = [UIColor secondaryLabelColor];
    _fileInfoLabel.textAlignment = NSTextAlignmentRight;
    _fileInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_fileInfoLabel];

    _waveformView = [[WaveformScrubberView alloc] initWithFrame:CGRectZero];
    _waveformView.delegate = self;
    _waveformView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_waveformView];

    _elapsedLabel = [self makeTimeLabel];
    _remainingLabel = [self makeTimeLabel];
    _remainingLabel.textAlignment = NSTextAlignmentRight;
    [root addSubview:_elapsedLabel];
    [root addSubview:_remainingLabel];

    _playPauseButton = [self makeTransportButton:@"play.fill" pointSize:44
                                          action:@selector(playPauseTapped)];
    _playPauseButton.accessibilityLabel = STR_TRANSPORT_PLAY;
    _nextButton = [self makeTransportButton:@"forward.fill" pointSize:26
                                     action:@selector(nextTapped)];
    _nextButton.accessibilityLabel = STR_TRANSPORT_NEXT;

    UIStackView *transport = [[UIStackView alloc] initWithArrangedSubviews:@[
            _playPauseButton, _nextButton]];
    transport.axis = UILayoutConstraintAxisHorizontal;
    transport.alignment = UIStackViewAlignmentCenter;
    transport.spacing = 56;
    transport.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:transport];

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

    _emptyStateTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                             action:@selector(emptyStateTapped)];
    [root addGestureRecognizer:_emptyStateTap];

    // Directory navigation: swipe left for the next track, right for the
    // previous, anywhere that is not the waveform (which owns its pans).
    UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc]
            initWithTarget:self action:@selector(swipeNext)];
    swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
    swipeLeft.delegate = self;
    [root addGestureRecognizer:swipeLeft];
    UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc]
            initWithTarget:self action:@selector(swipePrevious)];
    swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
    swipeRight.delegate = self;
    [root addGestureRecognizer:swipeRight];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    // The band between the header and the waveform; the transport centers in
    // it vertically.
    UILayoutGuide *middle = [[UILayoutGuide alloc] init];
    [root addLayoutGuide:middle];

    [NSLayoutConstraint activateConstraints:@[
        [_backgroundArtView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_backgroundArtView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_backgroundArtView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_backgroundArtView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_backgroundBlurView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_backgroundBlurView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_backgroundBlurView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_backgroundBlurView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],

        // The mac header's arrangement: artist small over the title on the
        // left, the codec corner right-aligned on the artist line.
        [_artistLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [_artistLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_fileInfoLabel.firstBaselineAnchor constraintEqualToAnchor:_artistLabel.firstBaselineAnchor],
        [_fileInfoLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [_fileInfoLabel.leadingAnchor
                constraintGreaterThanOrEqualToAnchor:_artistLabel.trailingAnchor constant:12],
        [_titleLabel.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor constant:2],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],

        [middle.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor],
        [middle.bottomAnchor constraintEqualToAnchor:_waveformView.topAnchor],
        [transport.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [transport.centerYAnchor constraintEqualToAnchor:middle.centerYAnchor],

        // Full-bleed waveform above the time labels and the bottom bar.
        [_waveformView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_waveformView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_waveformView.bottomAnchor constraintEqualToAnchor:_searchBarButton.topAnchor constant:-44],
        [_waveformView.heightAnchor constraintEqualToConstant:90],

        [_elapsedLabel.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor constant:6],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_remainingLabel.topAnchor constraintEqualToAnchor:_elapsedLabel.topAnchor],
        [_remainingLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

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
    // The waveform owns horizontal drags for scrubbing; directory swipes
    // apply everywhere else.
    return !CGRectContainsPoint(_waveformView.frame, [touch locationInView:self.view]);
}

- (void)swipeNext {
    [self nextTapped];
}

- (void)swipePrevious {
    if ([_playlist previous]) {
        [self playCurrentTrack];
    }
}

#pragma mark - Header rendering

- (void)showEmptyState {
    _titleLabel.text = STR_LABEL_OPEN_HINT_IOS;
    _titleLabel.textColor = [UIColor secondaryLabelColor];
    _artistLabel.text = @"";
    _fileInfoLabel.text = @"";
    [self setBackgroundArt:nil];
    _elapsedLabel.text = STR_LABEL_TIME_UNKNOWN;
    _remainingLabel.text = STR_LABEL_TIME_UNKNOWN;
    [_waveformView showEmptyPlaceholder];
    _emptyStateTap.enabled = YES;
}

- (void)renderHeaderForTrack:(AudioTrack *)track {
    _emptyStateTap.enabled = NO;
    _titleLabel.textColor = [UIColor labelColor];
    // The artist has its own line, so the title line carries the title alone
    // when both are tagged.
    _titleLabel.text = track.hasArtistAndTitle ? track.title : track.singleLineTitle;
    if (_errorText) {
        _artistLabel.text = _errorText;
        _artistLabel.textColor = [UIColor systemRedColor];
    }
    else {
        _artistLabel.text = track.hasArtistAndTitle ? track.artist : @"";
        _artistLabel.textColor = [UIColor secondaryLabelColor];
    }
    _fileInfoLabel.text = [self fileInfoTextForTrack:track];
    [self setBackgroundArt:(track.albumArt ?: track.thumbnailAlbumArt)];
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

- (void)setBackgroundArt:(VibeImage *)art {
    if (_backgroundArtView.image == art) {
        return;
    }
    [UIView transitionWithView:_backgroundArtView
                      duration:0.35
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        self->_backgroundArtView.image = art;
                    }
                    completion:nil];
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
}

- (void)updatePlaybackUI {
    NSTimeInterval position = _player.position;
    NSTimeInterval duration = _player.duration;
    if (duration > 0) {
        Formatters *formatters = [Formatters sharedInstance];
        _elapsedLabel.text = [formatters durationStringFromTimeInterval:position];
        _remainingLabel.text = [formatters durationStringFromTimeInterval:MAX(0, duration - position)];
        if (!_waveformView.isScrubbing) {
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
    [_audioSession activate];
    [self renderHeaderForTrack:track];
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
    [self renderHeaderForTrack:track];
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

- (void)emptyStateTapped {
    if (_playlist.count == 0) {
        [_folderSession presentPickerFromViewController:self];
    }
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
        _artistLabel.text = STR_ERROR_FOLDER_EMPTY;
        _artistLabel.textColor = [UIColor secondaryLabelColor];
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
    if (!playing) {
        [_audioSession deactivateWhenIdle];
    }
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    _updateTimer.wanted = NO;
    [_audioSession deactivateWhenIdle];
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
    _updateTimer.wanted = YES;
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track {
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
    [_waveformView hideLoadingIndicator];
    if (current) {
        [self renderHeaderForTrack:current];
    }
    _updateTimer.wanted = NO;
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
    }
    if ([_playlist isCurrentTrack:track]) {
        [self renderHeaderForTrack:track];
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
    _updateTimer.wanted = NO;
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
