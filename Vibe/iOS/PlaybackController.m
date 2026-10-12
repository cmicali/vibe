//
//  PlaybackController.m
//  Vibe (iOS)
//
//  The player callbacks, the Now Playing bridge and the open roads are
//  categories sharing PlaybackControllerInternal.h.
//

#import "PlaybackControllerInternal.h"
#import "WidgetPublisher.h"
#import "PlaybackController+NowPlaying.h"
#import "PlaybackController+PlayerEvents.h"

#import "AppSettings.h"
#import "AudioFX.h"
#import "AudioFXMath.h"
#import "AudioPlayer.h"
#import "StallWatch.h"
#import "AudioPlayer+Recovery.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "CloudTransferRegistry.h"
#import "DropboxMirror.h"
#import "SettingsRules.h"
#import "UIUpdateTimer.h"

// Fixed, unlike the mac's (Util/UIUpdateMath.h): a display link moves the
// playhead here; this tick feeds only the time labels and Now Playing.
static const NSUInteger kUIUpdateHz = 3;

@implementation PlaybackController {
    // Weak: an observer is a view or view controller. NSPointerArray keeps
    // registration order, which NSHashTable cannot.
    NSPointerArray *_observers;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _observers = [NSPointerArray weakObjectsPointerArray];

        _playlist = [[Playlist alloc] init];
        _playlist.observer = self;
        _metadataCache = [[AudioTrackMetadataCache alloc] init];
        _metadataCache.delegate = self;
        _folderSession = [[FolderSession alloc] init];
        _folderSession.delegate = self;
        _nowPlaying = [[NowPlayingController alloc] initWithDelegate:self];
        // Before any restore, so a shuffled restore starts its order on the
        // remembered row.
        [self pushTransportModes];
        _widgetPublisher = [[WidgetPublisher alloc] init];
        _launchOpenWaiters = [NSMutableArray array];
        // The setting as is: no bit-perfect mode here to outrank it.
        _player = [[AudioPlayer alloc] initWithDeviceUID:@"" name:@""
                                                enableFX:AppSettings.sharedInstance.audioFXEnabled
                                                delegate:self];
        _player.crossfadeMilliseconds = AppSettings.sharedInstance.crossfadeMilliseconds;

        __weak PlaybackController *weakSelf = self;
        _updateTimer = [[UIUpdateTimer alloc] initWithHz:kUIUpdateHz handler:^{
            [weakSelf notifyDidTick];
        }];
        // Fail closed until the scene delegate reports foreground-active.
        _updateTimer.windowVisible = NO;
        // Last: the media-reset notification arrives on its own thread, so
        // everything it can reach must exist before observation starts.
        _audioSession = [[AudioSessionController alloc] initWithDelegate:self];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(thumbnailDidLoad:)
                                                   name:AudioTrackMetadataThumbnailDidLoadNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(dropboxAccountDidChange:)
                                                   name:VibeDropboxAccountDidChangeNotification
                                                 object:DropboxMirror.shared.client];
        [CloudTransferRegistry.sharedRegistry addObserver:self];
    }
    return self;
}

// Signed out, or revoked on dropbox.com: the mirror is being deleted and its
// placeholders can no longer download, so a playlist reaching into it goes
// whole, as Clear Playlist does — never a row edit (AGENTS.md).
- (void)dropboxAccountDidChange:(NSNotification *)notification {
    DropboxMirror *mirror = DropboxMirror.shared;
    if (mirror.client.isLinked) {
        return;
    }
    for (AudioTrack *track in _playlist.tracks) {
        if ([mirror containsURL:track.url]) {
            LogInfo(@"Dropbox: account gone, clearing a playlist in its mirror");
            [self clearPlaylist];
            return;
        }
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)thumbnailDidLoad:(NSNotification *)notification {
    AudioTrack *displayed = self.displayedTrack;
    if (displayed.metadata == notification.object) {
        [self publishNowPlaying];
    }
}

#pragma mark - Observers

- (void)addObserver:(id<PlaybackObserver>)observer {
    BOOL hasDeadObserver = NO;
    for (NSUInteger index = 0; index < _observers.count; index++) {
        id<PlaybackObserver> existing = (__bridge id)[_observers pointerAtIndex:index];
        if (existing == observer) {
            return;
        }
        hasDeadObserver |= existing == nil;
    }
    if (hasDeadObserver) {
        [_observers compact];
    }
    [_observers addPointer:(__bridge void *)observer];
}

- (void)removeObserver:(id<PlaybackObserver>)observer {
    for (NSUInteger index = _observers.count; index > 0; index--) {
        id<PlaybackObserver> existing =
                (__bridge id)[_observers pointerAtIndex:index - 1];
        if (!existing || existing == observer) {
            [_observers removePointerAtIndex:index - 1];
        }
    }
}

// A handler may add or drop an observer mid-delivery.
- (NSArray<id<PlaybackObserver>> *)observerSnapshot {
    NSMutableArray<id<PlaybackObserver>> *snapshot =
            [NSMutableArray arrayWithCapacity:_observers.count];
    BOOL hasDeadObserver = NO;
    for (NSUInteger index = 0; index < _observers.count; index++) {
        id<PlaybackObserver> observer =
                (__bridge id)[_observers pointerAtIndex:index];
        if (observer) {
            [snapshot addObject:observer];
        }
        else {
            hasDeadObserver = YES;
        }
    }
    if (hasDeadObserver) {
        [_observers compact];
    }
    return snapshot;
}

- (void)notifyDidMoveToCurrentTrackAnimated:(BOOL)animated {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidMoveToCurrentTrack:animated:)]) {
            [observer playbackDidMoveToCurrentTrack:self animated:animated];
        }
    }
}

- (void)notifyDidRenderCurrentTrack {
    // Every path that changes which track is current comes through here, so
    // it is where the delay taps learn the new track's tempo. It is also where
    // the lock screen and the widgets learn the track, before its file opens.
    // In the background no tick publishes sooner, and a widget's skip showed
    // the old track for as long as the open took.
    [self refreshTempoFeed];
    [self publishNowPlaying];
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidRenderCurrentTrack:)]) {
            [observer playbackDidRenderCurrentTrack:self];
        }
    }
}

- (void)notifyDidChangePlayState {
    [self syncLevelsEnabled];
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidChangePlayState:)]) {
            [observer playbackDidChangePlayState:self];
        }
    }
}

- (void)notifyDidChangeOutputRoute {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidChangeOutputRoute:)]) {
            [observer playbackDidChangeOutputRoute:self];
        }
    }
}

#pragma mark - The output route

- (VibeOutputRouteKind)outputRouteKind {
    return _audioSession.outputRouteKind;
}

- (NSString *)outputRouteName {
    return _audioSession.outputRouteName;
}

#pragma mark - Equalizer levels

// _levelConsumers is demand the shells already folded over visibility. The
// scene and audio facts stay here as fail-closed gates, so a stale view cannot
// spend FFT work on its own.
- (void)syncLevelsEnabled {
    _player.levelsEnabled = _levelConsumers > 0 && _sceneActive
            && _player.outputAudioActive;
}

- (void)setSceneActive:(BOOL)sceneActive {
    if (_sceneActive == sceneActive) {
        return;
    }
    _sceneActive = sceneActive;
    LogInfo(@"Scene: %@", sceneActive ? @"active" : @"inactive");
    _updateTimer.windowVisible = sceneActive;
    VibeStallWatchNoteSceneActive(sceneActive);
    [self syncLevelsEnabled];
    if (sceneActive) {
        // The one moment a widget can have been removed (WidgetPublisher.h).
        [_widgetPublisher refreshPlaced];
        [self notifyDidTick];
    }
}

- (BOOL)isSceneActive {
    return _sceneActive;
}

- (BOOL)audioOutputActive {
    return _player.outputAudioActive;
}

// Counted: cell reuse briefly holds two consumers. EqualizerIndicatorView
// guarantees one NO per YES, dealloc included.
- (void)equalizerLevelsWanted:(BOOL)wanted {
    if (wanted) {
        _levelConsumers++;
    }
    else {
        NSAssert(_levelConsumers > 0, @"unbalanced equalizer level demand");
        if (_levelConsumers == 0) {
            return;
        }
        _levelConsumers--;
    }
    [self syncLevelsEnabled];
}

- (BOOL)copyEqualizerLevels:(float *)out
                      count:(NSUInteger)count
                   sequence:(uint64_t *)sequence {
    return [_player copyBandLevels:out count:count sequence:sequence];
}

- (void)notifyDidTick {
    [self publishNowPlaying];
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidTick:)]) {
            [observer playbackDidTick:self];
        }
    }
}

- (void)notifyDidBeginLoading {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidBeginLoading:)]) {
            [observer playbackDidBeginLoading:self];
        }
    }
}

- (void)notifyDidUpdateLoadingProgress:(float)fraction {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playback:didUpdateLoadingProgress:)]) {
            [observer playback:self didUpdateLoadingProgress:fraction];
        }
    }
}

- (void)notifyDidFinishLoading {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidFinishLoading:)]) {
            [observer playbackDidFinishLoading:self];
        }
    }
}

- (void)notifyDidFailCurrentTrack {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidFailCurrentTrack:)]) {
            [observer playbackDidFailCurrentTrack:self];
        }
    }
}

- (void)notifyHasNothingToRestore {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackHasNothingToRestore:)]) {
            [observer playbackHasNothingToRestore:self];
        }
    }
}

#pragma mark - What there is to play

- (AudioTrack *)currentTrack {
    return _playlist.currentTrack;
}

- (NSUInteger)currentIndex {
    return _playlist.currentIndex;
}

- (NSString *)folderDisplayName {
    return _folderSession.folderDisplayName;
}

- (BOOL)playlistHasAdditions {
    return _folderSession.hasAdditions;
}

#pragma mark - Display state

- (VibePlayerScreenState)screenState {
    return VibeResolvePlayerScreenState(_playlist.count, _trackStartPending,
                                        _parked, _errorText != nil,
                                        _player.duration);
}

- (AudioTrack *)displayedTrack {
    return VibePlayerScreenDescribesTrack(self.screenState) ? _playlist.currentTrack : nil;
}

- (NSString *)errorText {
    return _errorText;
}

- (BOOL)isPlaying {
    return _player.isPlaying;
}

- (NSTimeInterval)position {
    return _player.position;
}

- (NSTimeInterval)duration {
    return _player.duration;
}

- (BOOL)seekInFlight {
    return _seekInFlight;
}

- (BOOL)currentOpenSlow {
    return _loadingOpenRequestIdentifier != 0;
}

- (float)pendingSeekProgress {
    return _pendingSeekProgress;
}

#pragma mark - Transport

- (void)playCurrentTrack {
    AudioTrack *track = _playlist.currentTrack;
    if (!track) {
        return;
    }
    _errorText = nil;
    _parked = NO;
    _seekInFlight = NO;
    // Before the render, so the first draw shows the track at rest.
    _trackStartPending = YES;
    // The play is submitted before the repaint and the metadata kick so the
    // open waits behind neither; the session first, because a parked file
    // settles inline and starts the output unit at once.
    [_audioSession activate];
    // A replay of the same row moves no cursor.
    [self endLoadingProgress];
    [_player play:track];
    [self notifyDidRenderCurrentTrack];
    [self notifyDidMoveToCurrentTrackAnimated:YES];
    [_metadataCache loadMetadataNow:track];
    [self notifyDidChangePlayState];
}

// The twin of the mac's closeFile:. TRAP: stop fires no transport or
// track-end callback, so this method owns the reset; +PlayerEvents' stale-track
// guards drop any callback already in flight.
- (void)clearPlaylist {
    _replaceRequestSerial++;
    [self endOpening];
    [_player stop];
    [self endLoadingProgress];
    // TRAP: the session goes BEFORE the model. Clearing the model fires
    // playlistDidReplaceAllTracks:, which rebuilds the chrome; cleared after,
    // the session still answers folderURL and the bar keeps the old title and
    // star.
    [_folderSession clearSession];
    [_playlist clear];
    // Disarms the sweep's fallback timer.
    _metadataLoadPending = NO;
    _metadataLoadGeneration++;
    [_metadataCache cancelScan];
    _errorText = nil;
    _parked = NO;
    _seekInFlight = NO;
    _trackStartPending = NO;
    _updateTimer.wanted = NO;
    [_audioSession deactivateWhenIdle];
    // Not playbackDidOpenNewFolder:, which would raise the card over nothing.
    [self notifyDidRenderCurrentTrack];
    [self notifyDidChangePlayState];
    [self notifyDidTick];
    // LAST. A clear during a launch restore supersedes it, so nothing else
    // settles the launch waiters, and the settle is a latch: missed, every
    // later waiter parks and they all fire at some later open — a widget
    // intent skipping a track for no reason. Last because a waiter runs
    // arbitrary work and must not see a half-reset controller.
    [self settleLaunchOpen];
}

- (void)parkCurrentTrack {
    AudioTrack *track = _playlist.currentTrack;
    if (!track) {
        return;
    }
    _parked = YES;
    _seekInFlight = NO;
    _trackStartPending = NO;
    [self notifyDidRenderCurrentTrack];
    [self notifyDidMoveToCurrentTrackAnimated:NO];
    [_metadataCache loadMetadataNow:track];
    [self notifyDidChangePlayState];
}

- (void)playPause {
    if (_player.isPlaying) {
        [_player playPause];
    }
    else if (_player.isPaused || _player.isLoading) {
        // Loading here is a parked landing (a pause mid-load, or the
        // media-reset re-park). playPause flips it to playing; a fresh play:
        // would restart the open and lose the re-park's position.
        [_audioSession activate];
        [_player playPause];
    }
    else {
        [self playCurrentTrack];
    }
}

- (void)next {
    if ([_playlist next]) {
        [self playCurrentTrack];
    }
}

- (void)previous {
    // On the first row, Previous restarts the loaded track
    // (VibePlaybackPreviousIsAvailable).
    if ([_playlist previous]) {
        [self playCurrentTrack];
    }
    else if (!_player.isStopped) {
        [_player seekToPosition:0];
    }
}

#pragma mark - Settings

- (void)applyTrackTransitionSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    _player.crossfadeMilliseconds = settings.crossfadeMilliseconds;
    [self pushTransportModes];
    // prefetchTrack:nil unschedules an armed splice, so a mid-track switch to
    // Pause does not advance anyway; a new successor replaces one armed
    // before a repeat or shuffle change.
    [self prefetchSuccessor];
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidChangePlayOrder:)]) {
            [observer playbackDidChangePlayOrder:self];
        }
    }
    // Now Playing's next-track availability follows the modes.
    [self publishNowPlaying];
}

// The model and the system's controls, which show the same modes. With the
// card's buttons hidden, CarPlay's are too and both modes are off, whoever
// asked: a request that still arrives is written back as off here, and a mode
// saved before the buttons were hidden is cleared at launch.
- (void)pushTransportModes {
    AppSettings *settings = AppSettings.sharedInstance;
    BOOL shown = settings.showShuffleRepeat;
    if (!shown) {
        settings.shuffleEnabled = NO;
        settings.repeatMode = VibeRepeatModeOff;
    }
    _playlist.repeatMode = settings.repeatMode;
    _playlist.shuffleEnabled = settings.shuffleEnabled;
    _playlist.pauseAtTrackEnd = settings.pauseAtTrackEnd;
    [_nowPlaying updateShuffleEnabled:settings.shuffleEnabled
                           repeatMode:settings.repeatMode
                            available:shown];
}

- (void)toggleShuffle {
    AppSettings.sharedInstance.shuffleEnabled = !AppSettings.sharedInstance.shuffleEnabled;
    [self applyTrackTransitionSettings];
}

- (void)cycleRepeatMode {
    AppSettings.sharedInstance.repeatMode = VibeRepeatModeAfter(AppSettings.sharedInstance.repeatMode);
    [self applyTrackTransitionSettings];
}

- (void)applyFXSetting {
    // Off clears every stage's intent in the player, so a held pad has
    // nothing to leave behind.
    [_player setFXEnabled:AppSettings.sharedInstance.audioFXEnabled];
}

#pragma mark - Effects and tempo

- (void)setFXPadPosition:(CGPoint)position engaged:(BOOL)engaged {
    if (!engaged) {
        position = CGPointZero; // the corner is off on both axes
    }
    AudioFX *fx = _player.fx;
    fx.lowKillCutoffHz = VibeFXPadLowCutHz((float)position.y);
    fx.reverbSendLevel = VibeFXPadReverbLevel((float)position.x);
    fx.delaySendLevel = VibeFXPadDelayLevel((float)position.x);
}

// The tag over the analysis (AudioTrack.bpm), 0 when neither is known, which
// the FX read as the default. No pitch fader here, so the track's tempo is
// the tempo as heard. The setter no-ops on the same value.
- (void)refreshTempoFeed {
    _player.fx.delayTapBPM = _playlist.currentTrack.bpm;
}

- (void)noteDetectedBPM:(float)bpm forTrack:(AudioTrack *)analyzed {
    [_playlist stampTracksSounding:analyzed usingBlock:^(AudioTrack *track) {
        float shown = track.bpm;
        track.detectedBPM = bpm;
        // Only a tempo that changed what the row shows: the delivery repeats
        // on every load of the file, cache hits included, and a tag outranks
        // it. The event is the one a tag landing sends, so the page redraws
        // its codec line.
        if (track.bpm != shown) {
            [self notifyDidLoadMetadataForTrack:track];
        }
    }];
    [self refreshTempoFeed]; // a no-op unless the current track's tempo moved
}

// A list's rows can be stale (an external open replaced the playlist), and
// Playlist.setCurrentIndex does not range-check.
- (void)selectTrackAtIndex:(NSUInteger)index {
    if (index >= _playlist.count) {
        return;
    }
    _playlist.currentIndex = index;
    [self playCurrentTrack];
}

- (void)seekToProgress:(float)progress {
    progress = MIN(MAX(progress, 0), 1);
    NSTimeInterval duration = _player.duration;
    if (duration > 0) {
        _pendingSeekProgress = progress;
        _seekInFlight = YES;
        [_player seekToPosition:duration * progress];
        return;
    }
    // Parked, or an open still in flight: the player holds no file, so the
    // metadata's duration opens it AT the target, paused — a scrub moves the
    // playhead and nothing else.
    AudioTrack *track = _playlist.currentTrack;
    if (!track || !(_parked || _player.isLoading)) {
        return;
    }
    _pendingSeekProgress = progress;
    _seekInFlight = YES;
    if (track.duration <= 0) {
        // No duration yet (a widget seek on a cold launch lands here every
        // time). The target is kept and didLoadMetadata: re-enters.
        return;
    }
    if (_parked) {
        // Holds the waveform on the target through the open. A second seek
        // rebinds the same-file request rather than opening again.
        [self openParkedTrack:track atPosition:track.duration * progress];
        [self notifyDidChangePlayState];
        return;
    }
    [_player seekToPosition:track.duration * progress];
}

- (void)seekToPosition:(NSTimeInterval)position {
    NSTimeInterval duration = _player.duration;
    if (duration <= 0) {
        duration = _playlist.currentTrack.duration;
    }
    if (duration > 0) {
        [self seekToProgress:(float)(position / duration)];
        return;
    }
    if (_player.isLoading) {
        // No duration yet, but the open request takes an absolute position.
        _seekInFlight = YES;
        [_player seekToPosition:MAX(position, 0)];
    }
}

- (void)loadMetadataNowForTrack:(AudioTrack *)track {
    if (track) {
        [_metadataCache loadMetadataNow:track];
    }
}

#pragma mark - What the sweep does first

// Re-sent on every current-index change, the funnel every play, skip and
// auto-advance passes through; the ranking is the cache's.
- (void)updateMetadataNeighborhood {
    [_metadataCache setNeighborhoodTracks:_playlist.neighborhoodTracks];
}

#pragma mark - Transport follow-ups

// TRAP: the Stopped gate is load-bearing. A parked track holds no file.
// Prefetching over a list edit or a transition-setting change would open one.
// On a cloud folder that is an unasked download. A new play prefetches at
// start anyway.
- (void)prefetchSuccessor {
    if (_player.isStopped) {
        return;
    }
    [_player prefetchTrack:_playlist.trackEndSuccessor];
}

- (void)openParkedTrack:(AudioTrack *)track atPosition:(NSTimeInterval)position {
    _parked = YES;
    _trackStartPending = YES;
    [_player play:track atPosition:position startPaused:YES];
}

- (void)endLoadingProgress {
    _loadingURL = nil;
    _loadingPath = nil;
    _loadingOpenRequestIdentifier = 0;
    _loadingProgress = -1;
}

#pragma mark - The deferred metadata sweep

// The sweep waits for the picked track to settle: its workers would starve the
// player's open, on a provider folder for as long as each file takes to
// materialize. The fallback covers an open that never settles.
static const NSTimeInterval kDeferredMetadataFallbackSeconds = 2;

- (void)scheduleDeferredMetadataLoad {
    _metadataLoadPending = YES;
    NSUInteger generation = ++_metadataLoadGeneration;
    __weak PlaybackController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kDeferredMetadataFallbackSeconds * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
        PlaybackController *self = weakSelf;
        if (self && generation == self->_metadataLoadGeneration) {
            [self startPendingMetadataLoad];
        }
    });
}

- (void)startPendingMetadataLoad {
    if (!_metadataLoadPending) {
        return;
    }
    _metadataLoadPending = NO;
    [_metadataCache loadMetadata:_playlist.tracks];
}

#pragma mark - PlaylistObserver

- (void)playlistDidReplaceAllTracks:(Playlist *)playlist {
    // A replacement resets the index without the index-change event.
    [self endLoadingProgress];
    [self updateMetadataNeighborhood];
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidReplacePlaylist:)]) {
            [observer playbackDidReplacePlaylist:self];
        }
    }
}

- (void)playlist:(Playlist *)playlist didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playback:didAppendTracksAtIndexes:)]) {
            [observer playback:self didAppendTracksAtIndexes:indexes];
        }
    }
}

- (void)playlist:(Playlist *)playlist didReplaceTrackAtIndex:(NSUInteger)index {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playback:didReplaceTrackAtIndex:)]) {
            [observer playback:self didReplaceTrackAtIndex:index];
        }
    }
}

// iOS exposes no remove UI. A future caller must first coordinate the player;
// forwarding this model-only event would leave it playing the departed track.
- (void)playlist:(Playlist *)playlist didRemoveTracksAtIndexes:(NSIndexSet *)indexes {
}

// The removal's inverse; a no-op for the same reason.
- (void)playlist:(Playlist *)playlist didInsertTracksAtIndexes:(NSIndexSet *)indexes {
}

// No reorder UI either; a future one adds its own observer event.
- (void)playlist:(Playlist *)playlist
        didMoveTracksFromIndexes:(NSIndexSet *)sourceIndexes
                       toIndexes:(NSIndexSet *)destinationIndexes {
}

- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex {
    [self endLoadingProgress];
    [self updateMetadataNeighborhood];
    // The effects belong to the track they were played over: a change cuts
    // them, tails ringing out, before the card hears of it and drops its pad.
    [self setFXPadPosition:CGPointZero engaged:NO];
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playback:didChangeCurrentIndexFromIndex:)]) {
            [observer playback:self didChangeCurrentIndexFromIndex:previousIndex];
        }
    }
}

#pragma mark - AudioTrackMetadataCacheDelegate

- (void)notifyDidLoadMetadataForTrack:(AudioTrack *)track {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playback:didLoadMetadataForTrack:)]) {
            [observer playback:self didLoadMetadataForTrack:track];
        }
    }
}

- (void)didLoadMetadata:(AudioTrack *)track {
    [self notifyDidLoadMetadataForTrack:track];
    if ([_playlist isCurrentTrack:track]) {
        [self refreshTempoFeed]; // a BPM tag outranks the analysis
        // A parked seek that arrived before the duration lands now;
        // _trackStartPending says its open already started.
        if (_seekInFlight && _parked && !_trackStartPending && track.duration > 0) {
            [self seekToProgress:_pendingSeekProgress];
        }
        // A parked track's time labels render from this duration.
        [self notifyDidTick];
    }
}

#pragma mark - AudioSessionControllerDelegate

- (BOOL)audioSessionShouldPause:(AudioSessionController *)controller {
    BOOL wasPlaying = _player.isPlaying;
    // While Loading this requests a parked landing; a duplicate verdict stays
    // parked rather than toggling back to playing.
    [_player pause];
    return wasPlaying;
}

- (void)audioSessionShouldResume:(AudioSessionController *)controller {
    [_player resume];
    // An Ended that raced the pause fade still reads Playing, so resume alone
    // would leave an output the interruption stopped; recoverOutput is
    // idempotent.
    [_player recoverOutput];
}

- (void)audioSessionOutputRouteDidChange:(AudioSessionController *)controller {
    [self notifyDidChangeOutputRoute];
}

- (BOOL)audioSessionOutputIsIdle:(AudioSessionController *)controller {
    return _player.outputIdle;
}

- (void)audioSessionShouldRecoverOutput:(AudioSessionController *)controller {
    [_player recoverOutput];
}

- (void)audioSessionDidReceiveMediaServicesReset:(AudioSessionController *)controller {
    // On the notification thread: no main-confined state here. The completion
    // runs on main.
    __weak PlaybackController *weakSelf = self;
    [_player beginMediaServicesResetWithCompletion:
            ^(AudioTrack *resetTrack, NSTimeInterval position) {
        PlaybackController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_seekInFlight = NO;
        strongSelf->_updateTimer.wanted = NO;
        strongSelf->_trackStartPending = NO;
        AudioTrack *track = strongSelf->_playlist.currentTrack;
        // A restore may have replaced the row without a play; it owns its
        // parked state, and this older reset must not open its file.
        if (resetTrack && track == resetTrack) {
            [strongSelf openParkedTrack:resetTrack atPosition:position];
        }
        else if (!track) {
            strongSelf->_parked = NO;
        }
        // Published before the re-park's open can settle.
        [strongSelf notifyDidChangePlayState];
        [strongSelf notifyDidTick];
    }];
}

@end
