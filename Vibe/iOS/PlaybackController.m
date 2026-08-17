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
#import "AudioTrackMetadataCache.h"
#import "UIUpdateTimer.h"

// Fixed, unlike the mac's playhead-speed-scaled rate (Util/UIUpdateMath.h):
// there the timer is what moves the playhead, here a display link owns it on
// the screen that draws one. This tick only feeds the time labels, which
// change once a second, and the Now Playing publish.
static const NSUInteger kUIUpdateHz = 3;

@implementation PlaybackController {
    // Weakly held: an observer is a view or a view controller, and every one
    // of them outlives its registration only by accident.
    NSHashTable<id<PlaybackObserver>> *_observers;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _observers = [NSHashTable weakObjectsHashTable];

        _playlist = [[Playlist alloc] init];
        _playlist.observer = self;
        _metadataCache = [[AudioTrackMetadataCache alloc] init];
        _metadataCache.delegate = self;
        _audioSession = [[AudioSessionController alloc] init];
        _audioSession.delegate = self;
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
        _updateTimer.windowVisible = YES;

        // In the background the system extrapolates position from the last
        // Now Playing publish, so the tick is pure waste there — the same rule
        // as the mac window's occlusion gate.
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(sceneDidEnterBackground)
                       name:UISceneDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(sceneWillEnterForeground)
                       name:UISceneWillEnterForegroundNotification object:nil];
    }
    return self;
}

#pragma mark - Observers

- (void)addObserver:(id<PlaybackObserver>)observer {
    [_observers addObject:observer];
}

- (void)removeObserver:(id<PlaybackObserver>)observer {
    [_observers removeObject:observer];
}

// Snapshotted: a handler may add or drop an observer, and NSHashTable does not
// survive mutation under enumeration.
- (NSArray<id<PlaybackObserver>> *)observerSnapshot {
    return _observers.allObjects;
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
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidChangePlayState:)]) {
            [observer playbackDidChangePlayState:self];
        }
    }
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
    // AT the scrubbed position instead, and opened PAUSED.
    //
    // It used to call playCurrentTrack, which starts at zero and starts
    // playing: a scrub answered by throwing away the position the user just
    // chose and blasting the track from the top. A scrub is a request to move
    // the playhead and nothing else.
    AudioTrack *track = _playlist.currentTrack;
    if (!_parked || track.duration <= 0) {
        return;
    }
    _pendingSeekProgress = progress;
    _seekInFlight = YES;      // holds the waveform on the target through the open
    _trackStartPending = YES;
    [self notifyDidChangePlayState];
    [_player play:track atPosition:track.duration * progress startPaused:YES];
}

- (void)seekToPosition:(NSTimeInterval)position {
    [_player seekToPosition:position];
}

- (void)loadMetadataNowForTrack:(AudioTrack *)track {
    if (track) {
        [_metadataCache loadMetadataNow:track];
    }
}

#pragma mark - What the sweep does first

// The ranking itself — which neighbors, in what order — is the cache's, so
// both shells send the same one; see setNeighborhoodAroundIndex:inTracks:. It
// only matters on the cloud lane, where each parse is a whole file coming down
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

- (void)restorePersistedSession {
    if (![_folderSession restorePersistedFolder]) {
        [self notifyHasNothingToRestore];
    }
}

#pragma mark - Scene lifecycle

- (void)sceneDidEnterBackground {
    _updateTimer.windowVisible = NO;
}

- (void)sceneWillEnterForeground {
    _updateTimer.windowVisible = YES;
    [self notifyDidTick];
}

#pragma mark - FolderSessionDelegate

- (void)folderSession:(FolderSession *)session
        didOpenTracks:(NSArray<NSURL *> *)urls
            folderURL:(NSURL *)folderURL
          selectedURL:(NSURL *)selectedURL
             restored:(BOOL)restored {
    [_playlist replaceAllWithURLs:urls];
    [_metadataCache cancelAll];
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
    [self notifyDidChangePlayState];
    if (track) {
        _parked = YES;
        [_player play:track atPosition:position startPaused:YES];
    }
    else {
        [self notifyDidTick];
    }
}

@end
