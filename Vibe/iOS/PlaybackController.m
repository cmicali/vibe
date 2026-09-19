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
#import "WidgetPublisher.h"
#import "PlaybackController+NowPlaying.h"
#import "PlaybackController+PlayerEvents.h"   // AudioPlayerDelegate, adopted by the category

#import "AppSettings.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Recovery.h"
#import "AudioPlayer+Seek.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "FavoritesStore.h"
#import "PlaybackDeliveryRules.h"
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
        _widgetPublisher = [[WidgetPublisher alloc] init];
        _launchOpenWaiters = [NSMutableArray array];
        // TRAP: this must precede the player, and cannot move down to where
        // the session controller is created. AVAudioEngine wires its master
        // bus on the player's own queue moments after this init returns, and
        // instantiating the output unit runs against whatever category the
        // session carries — the system default, SoloAmbient, is not mixable,
        // so the engine's construction alone stopped whatever else the device
        // was playing at every cold launch, before the user had asked for a
        // track. Nothing is activated here; the play does that.
        [AudioSessionController prepareIdleCategory];
        // No FX on iOS: nothing surfaces them, so the FX graph segment is
        // never created or attached — the mixer wires straight to the output.
        // A hard NO, not the shared audioFXEnabled setting, so the mac default
        // cannot reach in here.
        _player = [[AudioPlayer alloc] initWithDeviceUID:@"" name:@"" enableFX:NO delegate:self];
        // The stored choice as is: no bit-perfect mode here to hold it down.
        _player.crossfadeMilliseconds = AppSettings.sharedInstance.crossfadeMilliseconds;


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
        // The one moment a widget can have been removed — see WidgetPublisher.h.
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
    // Re-park the successor, or drop it: prefetchTrack: with nil unschedules
    // an armed splice, which is what keeps a mid-track switch to Pause from
    // advancing anyway. Same shape as the mac's applyEndOfTrackAction.
    [_player prefetchTrack:self.successorPrefetchTrack];
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
    // playlist — or an open still in flight. The player holds no file, so its
    // duration is 0 and there is nothing to seek IN; the metadata knows the
    // length, so the file is opened AT the scrubbed position instead, and
    // opened PAUSED. A scrub is a request to move the playhead and nothing
    // else. Anything else has no open for a seek to land in.
    AudioTrack *track = _playlist.currentTrack;
    if (!track || !(_parked || _player.isLoading)) {
        return;
    }
    _pendingSeekProgress = progress;
    _seekInFlight = YES;
    if (track.duration <= 0) {
        // Before the metadata landed. A widget seek on a cold launch arrives
        // here every time: the launch open settles the moment the track is
        // parked, and its tags are still on the metadata lane. The target is
        // kept — the card already draws an in-flight seek at its target — and
        // didLoadMetadata: re-enters with the duration in hand. A play before
        // then starts from 0 and clears it, like any track event.
        return;
    }
    if (_parked) {
        // Holds the waveform on the target through the parked open. play:
        // rebinds an existing same-file request, so a second seek updates its
        // landing intent without starting another open or settling early.
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
    [_metadataCache setNeighborhoodAroundIndex:_playlist.currentIndex inTracks:_playlist];
}

#pragma mark - Transport follow-ups

// TRAP: the Stopped gate is load-bearing. A parked restored track is Stopped
// and holds no file, and prefetching over a mere list edit would open one — on
// a cloud folder, a download the user never asked for. A new play re-prefetches
// at start anyway; same rule as the mac's reconcileAfterPlaylistStructureEdit.
- (void)prefetchSuccessor {
    if (_player.isStopped) {
        return;
    }
    // Through successorPrefetchTrack, never around it: that is the single
    // home of the On track end = Pause rule, and a bypass would splice past a
    // track end the setting says to park on (root CLAUDE.md).
    [_player prefetchTrack:self.successorPrefetchTrack];
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

// One external open at a time: a share can mix in-place URLs with inbox
// copies, which open differently. The filename-sorted first is deterministic,
// unlike NSSet's anyObject, and when a folder grant covers its parent the
// expansion pulls the siblings in anyway.
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

// The whole search scope, composed here and nowhere else: the session's own
// transient roots — the base folder and every added folder — ahead of the
// persistent ones, which are the folders added in Settings plus the ones
// starred on the Favorites tab.
// Nesting among them is FileSearchIndex's to prune, so a folder that is both
// starred and added is walked once.
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
        NSString *remembered = session.persistedTrackPath;
        if (!selectedURL && remembered) {
            // Two tiers, exact path first. TRAP: the path alone is not enough —
            // a provider can hand the same file back under a different absolute
            // path, and the simulator's data-container UUID rotates on every
            // reinstall — so the filename remains the fallback, which is also
            // what restores a bare filename left by an older build. The scan
            // runs on: an exact hit anywhere outranks a filename hit, which is
            // the whole point once the playlist spans folders.
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
    }
    else {
        [self playCurrentTrack];
        for (id<PlaybackObserver> observer in [self observerSnapshot]) {
            if ([observer respondsToSelector:@selector(playbackDidOpenNewFolder:)]) {
                [observer playbackDidOpenNewFolder:self];
            }
        }
    }
    // After the park or the play, so a waiter finds a track to drive.
    [self settleLaunchOpen];
}

// iOS has no remove UI, so a double Add would be permanent: files already in
// the playlist are skipped, by standardized path like the selectedURL match
// above — Playlist's own URL index is NSURL isEqual:, which a picker URL and a
// listing URL of the same file need not satisfy. A shell decision; the model
// keeps allowing duplicates for the mac.
- (void)folderSession:(FolderSession *)session didAppendTracks:(NSArray<NSURL *> *)urls {
    NSMutableSet<NSString *> *present = [NSMutableSet set];
    for (AudioTrack *track in _playlist.tracks) {
        [present addObject:track.url.URLByStandardizingPath.path];
    }
    NSMutableArray<NSURL *> *fresh = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSString *path = url.URLByStandardizingPath.path;
        // One delivery already names each file once (FolderSession); the insert
        // keeps this loop correct on its own terms rather than on that promise.
        if (![present containsObject:path]) {
            [present addObject:path];
            [fresh addObject:url];
        }
    }
    if (fresh.count == 0) {
        return;                              // nothing new: no event, no sweep restart
    }
    [_playlist appendURLs:fresh];
    // The mac's re-queue; already-parsed tracks are skipped when it fires. No
    // cancelScan — that belongs to a replacement.
    [self scheduleDeferredMetadataLoad];
    [self updateMetadataNeighborhood];
    // A playing last row now has a successor: this arms the auto-advance into
    // the addition.
    [self prefetchSuccessor];
    // Publishes Now Playing (hasNext may have flipped) and then ticks; the 3 Hz
    // timer is off while parked or paused.
    [self notifyDidTick];
}

- (void)folderSessionDidOpenEmptyFolder:(FolderSession *)session {
    [self settleLaunchOpen];
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
    [self settleLaunchOpen];
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

// iOS exposes no remove UI. A future caller must first coordinate the player;
// forwarding this model-only event would leave it playing the departed track.
- (void)playlist:(Playlist *)playlist didRemoveTracksAtIndexes:(NSIndexSet *)indexes {
}

// The removal's inverse; a no-op for the same reason.
- (void)playlist:(Playlist *)playlist didInsertTracksAtIndexes:(NSIndexSet *)indexes {
}

// iOS exposes no reorder UI either. A move is transport-safe at the model
// boundary — the current object survives — but a future caller still goes
// through this controller and adds the screen reconciliation its feature
// needs; no speculative PlaybackObserver event until then.
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
        // A seek that arrived parked before this delivery (seekToProgress:)
        // lands now, through the same funnel. !_trackStartPending is what says
        // it has not already opened: the parked open sets it.
        if (_seekInFlight && _parked && !_trackStartPending && track.duration > 0) {
            [self seekToProgress:_pendingSeekProgress];
        }
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
