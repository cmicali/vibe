//
//  PlaybackController.m
//  Vibe (iOS)
//
//  The player callbacks and the Now Playing bridge are categories sharing
//  PlaybackControllerInternal.h.
//

#import "PlaybackControllerInternal.h"
#import "WidgetPublisher.h"
#import "PlaybackController+NowPlaying.h"
#import "PlaybackController+PlayerEvents.h"

#import "AppSettings.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Diagnostics.h"
#import "AudioPlayer+Recovery.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "DownloadProgressMonitor.h"
#import "FavoritesStore.h"
#import "PlaybackDeliveryRules.h"
#import "SearchFolderStore.h"
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
        _widgetPublisher = [[WidgetPublisher alloc] init];
        _launchOpenWaiters = [NSMutableArray array];
        // No FX on iOS (root CLAUDE.md).
        _player = [[AudioPlayer alloc] initWithDeviceUID:@"" name:@"" enableFX:NO delegate:self];
        _player.crossfadeMilliseconds = AppSettings.sharedInstance.crossfadeMilliseconds;
        [self applyResamplingSetting];


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
    }
    return self;
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
    _updateTimer.windowVisible = sceneActive;
    [AudioPlayer noteSceneActive:sceneActive];
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
    [_player stop];
    [_downloadMonitor cancel];
    _downloadMonitor = nil;
    _downloadMonitorOpenRequestIdentifier = 0;
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
    if ([_playlist previous]) {
        [self playCurrentTrack];
    }
    else {
        [_player seekToPosition:0];
    }
}

#pragma mark - Settings

- (AudioTrack *)successorPrefetchTrack {
    if (!VibePlaybackShouldAdvanceAtTrackEnd(_playlist.hasNextTrack,
                                            AppSettings.sharedInstance.pauseAtTrackEnd)) {
        return nil;
    }
    return [_playlist trackAtIndex:_playlist.currentIndex + 1];
}

- (void)applyTrackTransitionSettings {
    _player.crossfadeMilliseconds = AppSettings.sharedInstance.crossfadeMilliseconds;
    // prefetchTrack:nil unschedules an armed splice, so a mid-track switch to
    // Pause does not advance anyway.
    [_player prefetchTrack:self.successorPrefetchTrack];
}

- (void)applyResamplingSetting {
    _player.resamplingQuality = AppSettings.sharedInstance.maximumResamplingQuality
            ? VibeResamplingQualityMaximum : VibeResamplingQualityHigh;
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
        _trackStartPending = YES;
        [self notifyDidChangePlayState];
        [_player play:track atPosition:track.duration * progress startPaused:YES];
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
    [_metadataCache setNeighborhoodAroundIndex:_playlist.currentIndex inTracks:_playlist];
}

#pragma mark - Transport follow-ups

// TRAP: the Stopped gate is load-bearing. A parked track holds no file, and
// prefetching over a list edit would open one — on a cloud folder, an unasked
// download. A new play prefetches at start anyway.
- (void)prefetchSuccessor {
    if (_player.isStopped) {
        return;
    }
    // Never around successorPrefetchTrack: it holds On track end = Pause.
    [_player prefetchTrack:self.successorPrefetchTrack];
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

#pragma mark - Opening

- (void)presentPickerFromViewController:(UIViewController *)presenter {
    [_folderSession presentPickerFromViewController:presenter];
}

// One URL: a share can mix in-place URLs with inbox copies, which open
// differently. Filename order is deterministic, unlike anyObject, and a covering
// grant pulls the siblings in anyway.
- (void)handleOpenURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    UIOpenURLContext *context = [contexts.allObjects
            sortedArrayUsingComparator:^NSComparisonResult(UIOpenURLContext *a, UIOpenURLContext *b) {
        return [a.URL.lastPathComponent localizedStandardCompare:b.URL.lastPathComponent];
    }].firstObject;
    if (context) {
        [_folderSession openURLs:@[context.URL] openInPlace:context.options.openInPlace];
    }
}

- (void)openURLs:(NSArray<NSURL *> *)urls openInPlace:(BOOL)openInPlace {
    [_folderSession openURLs:urls openInPlace:openInPlace];
}

- (void)addURLs:(NSArray<NSURL *> *)urls {
    [_folderSession addURLs:urls];
}

- (uint64_t)addRequestToken {
    return _folderSession.addRequestToken;
}

- (void)addURLs:(NSArray<NSURL *> *)urls token:(uint64_t)token {
    [_folderSession addURLs:urls token:token];
}

- (NSURL *)folderURL {
    return _folderSession.folderURL;
}

- (void)bookmarkOpenFolderWithCompletion:(void (^)(NSURL *folderURL,
                                                   NSData *bookmark))completion {
    [_folderSession bookmarkOpenFolderWithCompletion:completion];
}

- (void)bookmarkFolderURL:(NSURL *)folderURL
               completion:(void (^)(NSData *bookmark))completion {
    [_folderSession bookmarkFolderURL:folderURL completion:completion];
}

// The only composition of the search scope: transient roots, then persistent
// ones. FileSearchIndex prunes the nesting.
- (NSArray<NSURL *> *)searchRoots {
    return [[_folderSession.searchRoots
            arrayByAddingObjectsFromArray:SearchFolderStore.shared.searchRoots]
            arrayByAddingObjectsFromArray:FavoritesStore.shared.searchRoots];
}

- (void)openSearchResultURL:(NSURL *)url {
    [_folderSession openFileFromSearchRoots:url];
}

- (void)restorePersistedSession {
    if (![_folderSession restorePersistedFolder]) {
        [self notifyHasNothingToRestore];
        [self settleLaunchOpen];
    }
}

- (void)performWhenLaunchOpenSettled:(void (^)(void))block {
    if (_launchOpenSettled) {
        block();
        return;
    }
    [_launchOpenWaiters addObject:[block copy]];
}

- (void)settleLaunchOpen {
    _launchOpenSettled = YES;
    NSArray<void (^)(void)> *waiters = [_launchOpenWaiters copy];
    [_launchOpenWaiters removeAllObjects];
    for (void (^waiter)(void) in waiters) {
        waiter();
    }
}

#pragma mark - FolderSessionDelegate

- (void)folderSession:(FolderSession *)session
        didOpenTracks:(NSArray<NSURL *> *)urls
            folderURL:(NSURL *)folderURL
          selectedURL:(NSURL *)selectedURL
             restored:(BOOL)restored {
    [_playlist replaceAllWithURLs:urls];
    [_metadataCache cancelScan];
    [self scheduleDeferredMetadataLoad];

    if (selectedURL) {
        // A file pick that expanded to its directory plays the picked file.
        NSString *selectedPath = selectedURL.URLByStandardizingPath.path;
        NSArray<AudioTrack *> *tracks = _playlist.tracks;
        for (NSUInteger i = 0; i < tracks.count; i++) {
            if ([tracks[i].url.URLByStandardizingPath.path isEqualToString:selectedPath]) {
                _playlist.currentIndex = i;
                break;
            }
        }
    }

    if (restored) {
        NSString *remembered = session.persistedTrackPath;
        if (!selectedURL && remembered) {
            // TRAP: the path alone is not enough — a provider can hand the file
            // back under a different path, and the simulator's container UUID
            // rotates on reinstall — so the filename is the fallback tier. An
            // exact hit anywhere outranks it, since the playlist spans folders.
            NSString *rememberedName = remembered.lastPathComponent;
            NSArray<AudioTrack *> *tracks = _playlist.tracks;
            NSUInteger match = NSNotFound;
            for (NSUInteger i = 0; i < tracks.count; i++) {
                NSString *path = tracks[i].url.URLByStandardizingPath.path;
                if ([path isEqualToString:remembered]) {
                    match = i;
                    break;
                }
                if (match == NSNotFound && [path.lastPathComponent isEqualToString:rememberedName]) {
                    match = i;
                }
            }
            if (match != NSNotFound) {
                _playlist.currentIndex = match;
            }
        }
        [self parkCurrentTrack];
        // A park opens nothing to starve and no didStartPlaying: will start
        // the sweep; left to the fallback, rows fill in two seconds late.
        [self startPendingMetadataLoad];
    }
    else {
        [self playCurrentTrack];
        for (id<PlaybackObserver> observer in [self observerSnapshot]) {
            if ([observer respondsToSelector:@selector(playbackDidOpenNewFolder:)]) {
                [observer playbackDidOpenNewFolder:self];
            }
        }
    }
    // After the park or play, so a waiter finds a track to drive.
    [self settleLaunchOpen];
}

// iOS has no remove UI, so a double Add would be permanent. Deduped by
// standardized path: a picker URL and a listing URL of one file need not be
// isEqual:. The model allows duplicates for the mac.
- (void)folderSession:(FolderSession *)session didAppendTracks:(NSArray<NSURL *> *)urls {
    NSMutableSet<NSString *> *present = [NSMutableSet set];
    for (AudioTrack *track in _playlist.tracks) {
        [present addObject:track.url.URLByStandardizingPath.path];
    }
    NSMutableArray<NSURL *> *fresh = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSString *path = url.URLByStandardizingPath.path;
        if (![present containsObject:path]) {
            [present addObject:path];
            [fresh addObject:url];
        }
    }
    if (fresh.count == 0) {
        return;
    }
    [_playlist appendURLs:fresh];
    // No cancelScan: that belongs to a replacement.
    [self scheduleDeferredMetadataLoad];
    [self updateMetadataNeighborhood];
    // A playing last row may now have a successor.
    [self prefetchSuccessor];
    // hasNext may have flipped, and the timer is off while parked or paused.
    [self notifyDidTick];
}

- (void)folderSessionDidOpenEmptyFolder:(FolderSession *)session {
    [self settleLaunchOpen];
    if (_playlist.count > 0) {
        return;   // a bad pick never wipes a good playlist
    }
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidOpenEmptyFolder:)]) {
            [observer playbackDidOpenEmptyFolder:self];
        }
    }
}

- (void)folderSessionRestoreDidFail:(FolderSession *)session {
    [self settleLaunchOpen];
    if (_playlist.count == 0) {
        [self notifyHasNothingToRestore];
    }
}

#pragma mark - PlaylistObserver

- (void)playlistDidReplaceAllTracks:(Playlist *)playlist {
    // A replacement resets the index without the index-change event.
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
    [self updateMetadataNeighborhood];
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playback:didChangeCurrentIndexFromIndex:)]) {
            [observer playback:self didChangeCurrentIndexFromIndex:previousIndex];
        }
    }
}

#pragma mark - AudioTrackMetadataCacheDelegate

- (void)didLoadMetadata:(AudioTrack *)track {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playback:didLoadMetadataForTrack:)]) {
            [observer playback:self didLoadMetadataForTrack:track];
        }
    }
    if ([_playlist isCurrentTrack:track]) {
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
            strongSelf->_parked = YES;
            strongSelf->_trackStartPending = YES;
            [strongSelf->_player play:resetTrack
                           atPosition:position
                          startPaused:YES];
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
