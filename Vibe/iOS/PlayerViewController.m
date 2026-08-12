//
//  PlayerViewController.m
//  Vibe (iOS)
//

#import "PlayerViewController.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioSessionController.h"
#import "FolderSession.h"
#import "Playlist.h"
#import "NowPlayingController.h"
#import "TrackListViewController.h"
#import "UIUpdateTimer.h"
#import "Formatters.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"

static const NSUInteger kUIUpdateHz = 3;

@interface PlayerViewController () <AudioPlayerDelegate, PlaylistObserver,
        AudioTrackMetadataCacheDelegate, AudioWaveformCacheDelegate,
        WaveformScrubberViewDelegate, NowPlayingControllerDelegate,
        AudioSessionControllerDelegate, FolderSessionDelegate>
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

    UIImageView             *_artworkView;
    UILabel                 *_titleLabel;
    UILabel                 *_artistLabel;
    WaveformScrubberView    *_waveformView;
    UILabel                 *_elapsedLabel;
    UILabel                 *_remainingLabel;
    UIButton                *_playlistButton;
    UIButton                *_playPauseButton;
    UIButton                *_nextButton;
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

    _artworkView = [[UIImageView alloc] init];
    _artworkView.contentMode = UIViewContentModeScaleAspectFit;
    _artworkView.layer.cornerRadius = 12;
    _artworkView.clipsToBounds = YES;
    _artworkView.backgroundColor = [UIColor tertiarySystemFillColor];
    _artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_artworkView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 2;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_titleLabel];

    _artistLabel = [[UILabel alloc] init];
    _artistLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _artistLabel.textColor = [UIColor secondaryLabelColor];
    _artistLabel.textAlignment = NSTextAlignmentCenter;
    _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_artistLabel];

    _waveformView = [[WaveformScrubberView alloc] initWithFrame:CGRectZero];
    _waveformView.delegate = self;
    _waveformView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_waveformView];

    _elapsedLabel = [self makeTimeLabel];
    _remainingLabel = [self makeTimeLabel];
    _remainingLabel.textAlignment = NSTextAlignmentRight;
    [root addSubview:_elapsedLabel];
    [root addSubview:_remainingLabel];

    _playlistButton = [self makeTransportButton:@"list.bullet" pointSize:22
                                         action:@selector(playlistTapped)];
    _playlistButton.accessibilityLabel = STR_A11Y_TOGGLE_PLAYLIST;
    _playPauseButton = [self makeTransportButton:@"play.fill" pointSize:40
                                          action:@selector(playPauseTapped)];
    _playPauseButton.accessibilityLabel = STR_TRANSPORT_PLAY;
    _nextButton = [self makeTransportButton:@"forward.fill" pointSize:22
                                     action:@selector(nextTapped)];
    _nextButton.accessibilityLabel = STR_TRANSPORT_NEXT;

    UIStackView *transport = [[UIStackView alloc] initWithArrangedSubviews:@[
            _playlistButton, _playPauseButton, _nextButton]];
    transport.axis = UILayoutConstraintAxisHorizontal;
    transport.alignment = UIStackViewAlignmentCenter;
    transport.distribution = UIStackViewDistributionEqualCentering;
    transport.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:transport];

    _emptyStateTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                             action:@selector(emptyStateTapped)];
    [root addGestureRecognizer:_emptyStateTap];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_artworkView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:32],
        [_artworkView.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_artworkView.widthAnchor constraintEqualToAnchor:root.widthAnchor multiplier:0.62],
        [_artworkView.heightAnchor constraintEqualToAnchor:_artworkView.widthAnchor],

        [_titleLabel.topAnchor constraintEqualToAnchor:_artworkView.bottomAnchor constant:24],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],

        [_artistLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
        [_artistLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_artistLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],

        [transport.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:48],
        [transport.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-48],
        [transport.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-24],
        [transport.heightAnchor constraintEqualToConstant:72],

        // Full-bleed, like the SoundCloud player: the waveform runs edge to
        // edge, above the time labels and transport.
        [_waveformView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_waveformView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_waveformView.bottomAnchor constraintEqualToAnchor:transport.topAnchor constant:-48],
        [_waveformView.heightAnchor constraintEqualToConstant:90],

        [_elapsedLabel.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor constant:6],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_remainingLabel.topAnchor constraintEqualToAnchor:_elapsedLabel.topAnchor],
        [_remainingLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
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

#pragma mark - Header rendering

- (void)showEmptyState {
    _titleLabel.text = STR_LABEL_OPEN_HINT_IOS;
    _titleLabel.textColor = [UIColor secondaryLabelColor];
    _artistLabel.text = @"";
    _artworkView.image = nil;
    _elapsedLabel.text = STR_LABEL_TIME_UNKNOWN;
    _remainingLabel.text = STR_LABEL_TIME_UNKNOWN;
    [_waveformView showEmptyPlaceholder];
    _emptyStateTap.enabled = YES;
}

- (void)renderHeaderForTrack:(AudioTrack *)track {
    _emptyStateTap.enabled = NO;
    _titleLabel.textColor = [UIColor labelColor];
    // The artist has its own line here, unlike the mac's single-line header,
    // so the title line carries the title alone when both are tagged.
    _titleLabel.text = track.hasArtistAndTitle ? track.title : track.singleLineTitle;
    if (_errorText) {
        _artistLabel.text = _errorText;
        _artistLabel.textColor = [UIColor systemRedColor];
    }
    else {
        _artistLabel.text = track.hasArtistAndTitle ? track.artist : @"";
        _artistLabel.textColor = [UIColor secondaryLabelColor];
    }
    VibeImage *art = track.albumArt ?: track.thumbnailAlbumArt;
    _artworkView.image = art;
    _artworkView.contentMode = UIViewContentModeScaleAspectFit;
}

- (void)updatePlayButton {
    BOOL playing = _player.isPlaying;
    NSString *symbol = playing ? @"pause.fill" : @"play.fill";
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:40
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
    _updateTimer.wanted = YES;
    [self updatePlayButton];
    [self updatePlaybackUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    _updateTimer.wanted = NO;
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

- (void)audioSessionShouldPause:(AudioSessionController *)controller {
    controller.wasPlayingAtInterruption = _player.isPlaying;
    if (_player.isPlaying) {
        [_player playPause];
    }
}

- (void)audioSessionShouldResume:(AudioSessionController *)controller {
    if (_player.isPaused) {
        [_audioSession activate];
        [_player playPause];
    }
}

@end
