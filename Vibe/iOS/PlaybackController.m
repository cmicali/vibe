//
//  PlaybackController.m
//  Vibe (iOS)
//
//  The coordination: the collaborators it owns, the broadcast, the transport
//  entry points, and the playlist, folder-session and audio-session delegates.
//  The player callbacks and the Now Playing bridge are categories — see
//  PlaybackControllerInternal.h for the surface they share.
//

#import "PlaybackControllerInternal.h"
#import "PlaybackController+NowPlaying.h"
#import "PlaybackController+PlayerEvents.h"   // AudioPlayerDelegate, adopted by the category

#import "AudioPlayer.h"
#import "AudioPlayer+Recovery.h"
#import "AudioPlayer+Seek.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "SearchFolderStore.h"
#import "UIUpdateTimer.h"

// Fixed, unlike the mac's playhead-speed-scaled rate (Util/UIUpdateMath.h):
// there the timer is what moves the playhead, here a display link owns it on
// the screen that draws one. This tick only feeds the time labels, which
// change once a second, and the Now Playing publish.
static const NSUInteger kUIUpdateHz = 3;

@implementation PlaybackController {
    // Weakly held: an observer is a view or a view controller, and every one
    // of them outlives its registration only by accident. NSPointerArray
    // keeps the public registration-order guarantee that NSHashTable cannot.
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
        // No FX on iOS: nothing surfaces them, so the FX graph segment is
        // never created or attached — the mixer wires straight to the output.
        // A hard NO, not the shared audioFXEnabled setting, so the mac default
        // cannot reach in here.
        _player = [[AudioPlayer alloc] initWithDeviceUID:@"" name:@"" enableFX:NO delegate:self];

        __weak PlaybackController *weakSelf = self;
        _updateTimer = [[UIUpdateTimer alloc] initWithHz:kUIUpdateHz handler:^{
            [weakSelf notifyDidTick];
        }];
        // Fail closed until VibeiOSSceneDelegate reports foreground-active.
        // A controller may be constructed while its scene is still inactive.
        _updateTimer.windowVisible = NO;
        // The media-reset receipt is delivered on its notification thread, so
        // session observation starts only after every collaborator it can
        // reach is ready and with its delegate installed atomically at init.
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

// Snapshotted: a handler may add or drop an observer without changing the
// recipients or registration order of the delivery already in progress.
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

// The tap exists to feed indicators, so it runs only while an indicator is
// actually reading it, the scene is active, and the graph is producing audio.
//
// _levelConsumers is the final demand declared by indicators after their shell
// has combined card, tab, controller-appearance and row-intersection facts.
// Count zero therefore means no equalizer is materially visible.
//
// RootViewController and LibraryViewController jointly decide presentation
// visibility before an indicator can declare demand. The scene and audio facts
// remain here as fail-closed producer gates, so a stale view cannot spend FFT
// work on its own.
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
    [self syncLevelsEnabled];
    if (sceneActive) {
        [self notifyDidTick];
    }
}

- (BOOL)isSceneActive {
    return _sceneActive;
}

- (BOOL)audioOutputActive {
    return _player.outputAudioActive;
}

// Counted rather than a flag: cell reuse hands the model to a new indicator
// before the old one lets go, so the count is briefly two and must not read as
// "nobody". EqualizerIndicatorView guarantees one NO per YES, dealloc included.
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

// Gathers the rule's inputs, sampling the player once so the whole state
// resolves against one consistent view of it.
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
    // Before the render, so the first draw already shows the track at rest.
    _trackStartPending = YES;
    [_audioSession activate];
    [self notifyDidRenderCurrentTrack];
    [self notifyDidMoveToCurrentTrackAnimated:YES];
    [_metadataCache loadMetadataNow:track];
    [_player play:track];
    [self notifyDidChangePlayState];
}

// Parks a restored track: everything renders, nothing plays.
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
        // Loading here is a parked landing (a pause verdict mid-load, or the
        // media-reset re-park): playPause flips the landing back to playing
        // without a fresh play:, which would restart the open and lose the
        // re-park's captured position. Same verdict as audioSessionShouldResume.
        [_audioSession activate];
        [_player playPause];
    }
    else {
        // Stopped: a parked restore, a finished playlist, or a failed track.
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

// Clamped because a list's rows can be stale — an external "Open in Vibe"
// replaces the playlist underneath an open screen, and Playlist.setCurrentIndex
// does not range-check, so a stale index would strand the cursor past the end.
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
    // Parked with nothing open — a relaunch restore, or the end of the
    // playlist. The player holds no file, so its duration is 0 and there is
    // nothing to seek IN; the metadata knows the length, so the file is opened
    // AT the scrubbed position instead, and opened PAUSED. A scrub is a request
    // to move the playhead and nothing else.
    AudioTrack *track = _playlist.currentTrack;
    if (track.duration <= 0) {
        return;
    }
    _pendingSeekProgress = progress;
    _seekInFlight = YES;
    if (_parked) {
        // Holds the waveform on the target through the parked open. play:
        // rebinds an existing same-file request, so a second seek updates its
        // landing intent without starting another open or settling early.
        _trackStartPending = YES;
        [self notifyDidChangePlayState];
        [_player play:track atPosition:track.duration * progress startPaused:YES];
        return;
    }
    if (_player.isLoading) {
        [_player seekToPosition:track.duration * progress];
        return;
    }
    _seekInFlight = NO;
}

- (void)seekToPosition:(NSTimeInterval)position {
    NSTimeInterval duration = _player.duration;
    if (duration <= 0) {
        duration = _playlist.currentTrack.duration;
    }
    if (duration > 0) {
        // The same funnel as an on-screen scrub is what opens a restored,
        // parked track paused at the requested absolute position.
        [self seekToProgress:(float)(position / duration)];
        return;
    }
    if (_player.isLoading) {
        // Duration metadata can still be pending, but AudioPlayer can update
        // the open request with an absolute file position already.
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

// The ranking itself — which neighbors, in what order — is the cache's, so
// both shells send the same one; see setNeighborhoodAroundIndex:inTracks:. It
// only matters on the scan lane, where each parse may pull a whole file down
// a wire and the sweep would otherwise work through the folder in filename
// order however far that is from where the user actually is. Re-sent on every
// current-index change, which is the one funnel every play, skip and
// auto-advance passes through.
- (void)updateMetadataNeighborhood {
    [_metadataCache setNeighborhoodAroundIndex:_playlist.currentIndex inTracks:_playlist.tracks];
}

#pragma mark - The deferred metadata sweep

// The playlist-wide sweep waits for the track the user picked to settle. Four
// workers reading every file in the folder starve the player's own open — on a
// file-provider folder they starve it for as long as the provider takes to
// materialize a file each, which is the difference between a track starting in
// a second and starting in a minute. The fallback covers an open that never
// settles at all. Its mac twin is MainPlayerController.scheduleDeferredMetadataLoad.
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

// One external open at a time: the session's playlist model is a directory,
// not an ad-hoc set. A multi-file share adopts the filename-sorted first —
// deterministic, unlike NSSet's anyObject — and when a folder grant covers
// its parent, the expansion pulls the siblings in anyway.
- (void)handleOpenURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    UIOpenURLContext *context = [contexts.allObjects
            sortedArrayUsingComparator:^NSComparisonResult(UIOpenURLContext *a, UIOpenURLContext *b) {
        return [a.URL.lastPathComponent localizedStandardCompare:b.URL.lastPathComponent];
    }].firstObject;
    if (context) {
        [_folderSession openExternalURL:context.URL openInPlace:context.options.openInPlace];
    }
}

- (void)openExternalURL:(NSURL *)url openInPlace:(BOOL)openInPlace {
    [_folderSession openExternalURL:url openInPlace:openInPlace];
}

// The whole search scope, composed here and nowhere else: the session's own
// transient root — the open folder — ahead of the persistent ones the store
// holds. Nesting among them is FileSearchIndex's to prune.
- (NSArray<NSURL *> *)searchRoots {
    NSURL *sessionRoot = _folderSession.searchRoot;
    NSArray<NSURL *> *persistent = SearchFolderStore.shared.searchRoots;
    return sessionRoot ? [@[sessionRoot] arrayByAddingObjectsFromArray:persistent] : persistent;
}

- (void)openSearchResultURL:(NSURL *)url {
    [_folderSession openFileFromSearchRoots:url];
}

- (void)restorePersistedSession {
    if (![_folderSession restorePersistedFolder]) {
        [self notifyHasNothingToRestore];
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
        // A file pick that expanded to its directory: play the picked file,
        // not the folder's first.
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
        NSString *fileName = session.persistedTrackFileName;
        if (!selectedURL && fileName) {
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
        for (id<PlaybackObserver> observer in [self observerSnapshot]) {
            if ([observer respondsToSelector:@selector(playbackDidOpenNewFolder:)]) {
                [observer playbackDidOpenNewFolder:self];
            }
        }
    }
}

- (void)folderSessionDidOpenEmptyFolder:(FolderSession *)session {
    if (_playlist.count > 0) {
        return;   // a good playlist is never wiped by a bad pick
    }
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidOpenEmptyFolder:)]) {
            [observer playbackDidOpenEmptyFolder:self];
        }
    }
}

- (void)folderSessionRestoreDidFail:(FolderSession *)session {
    if (_playlist.count == 0) {
        [self notifyHasNothingToRestore];
    }
}

#pragma mark - PlaylistObserver

- (void)playlistDidReplaceAllTracks:(Playlist *)playlist {
    // A replacement resets the index to 0 without moving it, so the
    // index-change hook below never fires for the first track of a new folder.
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
        // The full tick, not just the publish: a parked track's time labels
        // render from this delivery's duration.
        [self notifyDidTick];
    }
}

#pragma mark - AudioSessionControllerDelegate

- (BOOL)audioSessionShouldPause:(AudioSessionController *)controller {
    BOOL wasPlaying = _player.isPlaying;
    // The player decides beside its queue-confined state. While Loading this
    // requests a parked landing; duplicate route/interruption verdicts remain
    // parked rather than toggling it back to playing.
    [_player pause];
    return wasPlaying;
}

- (void)audioSessionShouldResume:(AudioSessionController *)controller {
    [_player resume];
    // If Ended raced the short pause fade, resume dissolves the pending pause
    // while the state still reads Playing. Follow it with the idempotent health
    // check so an engine already stopped by the interruption is rebuilt too.
    [_player recoverFromEngineConfigurationChange];
}

- (void)audioSessionOutputRouteDidChange:(AudioSessionController *)controller {
    [self notifyDidChangeOutputRoute];
}

- (void)audioSessionEngineConfigurationChanged:(AudioSessionController *)controller {
    [_player recoverFromEngineConfigurationChange];
}

- (void)audioSessionDidReceiveMediaServicesReset:(AudioSessionController *)controller {
    // Notification-thread edge: do not touch main-confined shell state here.
    // The player establishes the reset/play queue ordering now and hands the
    // pre-reset track plus its lock-only position cache back on main.
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
        // A model-only restore can replace the row without submitting a play.
        // It owns its parked state; this older reset must not open its file.
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
        // The reset's Stopped state is now authoritative. Publish it (or the
        // paused re-park's pending state) before its async open can settle.
        [strongSelf notifyDidChangePlayState];
        [strongSelf notifyDidTick];
    }];
}

@end
