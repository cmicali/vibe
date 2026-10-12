//
//  PlaybackController+Opening.m
//  Vibe (iOS)
//
//  The open and add roads into FolderSession, the row being opened, the
//  restore and the launch's settle, and the session's deliveries.
//

#import "PlaybackControllerInternal.h"

#import "AudioTrack.h"
#import "DropboxMirror.h"
#import "FavoritesStore.h"
#import "FilePaths.h"
#import "LocationStore.h"

@implementation PlaybackController (Opening)

#pragma mark - Opening

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
    [self submitReplaceOpening:urls.count == 1 ? urls.firstObject : nil];
    [_folderSession openURLs:urls openInPlace:openInPlace];
}

- (void)openSheetURL:(NSURL *)sheetURL inGrantedFolder:(NSURL *)folderURL appending:(BOOL)appending {
    if (!appending) {
        [self submitReplaceOpening:sheetURL];
    }
    [_folderSession openSheetURL:sheetURL inGrantedFolder:folderURL appending:appending];
}

- (void)addURLs:(NSArray<NSURL *> *)urls {
    [_folderSession addURLs:urls];
}

- (uint64_t)addRequestToken {
    return _folderSession.addRequestToken;
}

- (uint64_t)replaceRequestTokenOpening:(NSURL *)url {
    _replaceRequestSerial++;
    [self beginOpening:url];
    return _replaceRequestSerial;
}

#pragma mark - The row being opened

// Long enough for a Dropbox folder's listing (FolderSession's bound) and the
// read after it; past it the user is better told than left watching.
static const NSTimeInterval kOpeningTimeout = 25;

- (void)submitReplaceOpening:(NSURL *)url {
    _submittedOpenSerial = [self replaceRequestTokenOpening:url];
}

- (void)beginOpening:(NSURL *)url {
    _openingSerial = _replaceRequestSerial;
    NSString *path = url ? VibeComparablePath(url.path) : nil;
    if (path != _openingPath && ![path isEqualToString:_openingPath]) {
        _openingPath = path;
        [self notifyDidChangeOpening];
    }
    if (!path) {
        return;
    }
    uint64_t serial = _openingSerial;
    __weak PlaybackController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOpeningTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf giveUpOpening:serial];
    });
}

- (void)giveUpOpening:(uint64_t)serial {
    NSString *path = _openingPath;
    if (serial != _openingSerial || !path) {
        return;
    }
    LogWarn(@"PlaybackController: gave up opening %@ after %.0f s", path.lastPathComponent, kOpeningTimeout);
    [self cancelOpening];
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playback:didGiveUpOpeningPath:)]) {
            [observer playback:self didGiveUpOpeningPath:path];
        }
    }
}

- (void)cancelOpening {
    if (!_openingPath) {
        return;
    }
    // A resolve still running is dropped by the replace funnel; an open the
    // session holds, by the session.
    _replaceRequestSerial++;
    [self endOpening];
    if (_openingSerial == _submittedOpenSerial) {
        [_folderSession cancelOpen];
        [self notifyDidCancelOpening];
    }
}

- (void)endOpeningForReplaceRequest:(uint64_t)token {
    if (token == _openingSerial) {
        [self endOpening];
    }
}

- (void)endOpening {
    if (!_openingPath) {
        return;
    }
    _openingPath = nil;
    [self notifyDidChangeOpening];
}

- (void)notifyDidCancelOpening {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidCancelOpening:)]) {
            [observer playbackDidCancelOpening:self];
        }
    }
}

- (void)notifyDidChangeOpening {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidChangeOpening:)]) {
            [observer playbackDidChangeOpening:self];
        }
    }
}

- (NSString *)openingPath {
    return _openingPath;
}

- (BOOL)isCurrentReplaceRequest:(uint64_t)token {
    return token == _replaceRequestSerial;
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
// Never a Dropbox folder: the search screen's Dropbox section asks Dropbox,
// and a walk of the mirror would offer the same file twice from the folders
// already browsed.
- (NSArray<NSURL *> *)searchRoots {
    NSArray<NSURL *> *roots = [[_folderSession.searchRoots
            arrayByAddingObjectsFromArray:LocationStore.shared.searchRoots]
            arrayByAddingObjectsFromArray:FavoritesStore.shared.searchRoots];
    DropboxMirror *mirror = DropboxMirror.shared;
    return [roots filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSURL *root, NSDictionary *bindings) {
        return ![mirror containsURL:root];
    }]];
}

- (void)openFileURL:(NSURL *)url inFolder:(BOOL)inFolder {
    [self submitReplaceOpening:url];
    [_folderSession openURL:url inFolder:inFolder];
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
        didOpenTracks:(NSArray<AudioTrack *> *)rows
            folderURL:(NSURL *)folderURL
          selectedURL:(NSURL *)selectedURL
             restored:(BOOL)restored {
    // The start row is resolved from the rows and handed to the replace: set
    // after it, under shuffle it would be a pick (replaceAllWithTracks:'s trap).
    NSUInteger start = NSNotFound;
    if (selectedURL) {
        // A file pick that expanded to its directory plays the picked file;
        // a picked sheet, its first track.
        NSString *selectedPath = VibeComparablePath(selectedURL.path);
        for (NSUInteger i = 0; i < rows.count; i++) {
            if ([VibeComparablePath(rows[i].url.path) isEqualToString:selectedPath]
                    || [VibeComparablePath(rows[i].cueSheetURL.path) isEqualToString:selectedPath]) {
                start = i;
                break;
            }
        }
    }
    NSString *remembered = session.persistedTrackKey;
    if (restored && !selectedURL && remembered) {
        // TRAP: the path alone is not enough — a provider can hand the file
        // back under a different path, and the simulator's container UUID
        // rotates on reinstall — so the filename is the fallback tier. An
        // exact hit anywhere outranks it, since the playlist spans folders.
        // A cue row's window rides on both, so the row comes back, not the
        // file's first.
        NSString *rememberedName = remembered.lastPathComponent;
        for (NSUInteger i = 0; i < rows.count; i++) {
            NSString *key = rows[i].standardizedSourceKey;
            if ([key isEqualToString:remembered]) {
                start = i;
                break;
            }
            if (start == NSNotFound && [key.lastPathComponent isEqualToString:rememberedName]) {
                start = i;
            }
        }
    }
    [_playlist replaceAllWithTracks:rows startingAtIndex:start];
    [_metadataCache cancelScan];
    [self scheduleDeferredMetadataLoad];

    if (restored) {
        [self parkCurrentTrack];
        // A park opens nothing to starve and no didStartPlaying: will start
        // the sweep; left to the fallback, rows fill in two seconds late.
        [self startPendingMetadataLoad];
    }
    else {
        // What the session settles is the last replace it was handed; a row
        // asked for since is still resolving, and stays.
        [self endOpeningForReplaceRequest:_submittedOpenSerial];
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
// standardized path plus a cue row's window: a picker URL and a listing URL of
// one file need not be isEqual:, and rows of one file are distinct. The model
// allows duplicates for the mac.
- (void)folderSession:(FolderSession *)session didAppendTracks:(NSArray<AudioTrack *> *)rows {
    NSMutableSet<NSString *> *present = [NSMutableSet set];
    for (AudioTrack *track in _playlist.tracks) {
        NSString *key = track.standardizedSourceKey;
        if (key) {
            [present addObject:key];
        }
    }
    NSMutableArray<AudioTrack *> *fresh = [NSMutableArray array];
    for (AudioTrack *row in rows) {
        NSString *key = row.standardizedSourceKey;
        if (key && ![present containsObject:key]) {
            [present addObject:key];
            [fresh addObject:row];
        }
    }
    if (fresh.count > 0) {
        [_playlist appendTracks:fresh];
        // No cancelScan: that belongs to a replacement.
        [self scheduleDeferredMetadataLoad];
        [self updateMetadataNeighborhood];
        // A playing last row may now have a successor.
        [self prefetchSuccessor];
        // hasNext may have flipped, and the timer is off while parked or paused.
        [self notifyDidTick];
    }
    // After the append's own events: the request is over either way.
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playback:didSettleAddLanding:)]) {
            [observer playback:self didSettleAddLanding:fresh.count > 0];
        }
    }
}

// A bad pick never wipes a good playlist, and the observers hear of it either
// way: the open superseded every Add in flight, whose completions are dropped,
// so the rows the shell lifted for them settle on this event or never.
- (void)folderSessionDidOpenEmptyFolder:(FolderSession *)session {
    [self settleLaunchOpen];
    [self endOpeningForReplaceRequest:_submittedOpenSerial];
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playbackDidOpenEmptyFolder:)]) {
            [observer playbackDidOpenEmptyFolder:self];
        }
    }
}

- (void)folderSession:(FolderSession *)session
        needsFolderOfSheetAtURL:(NSURL *)sheetURL
                      appending:(BOOL)appending {
    for (id<PlaybackObserver> observer in [self observerSnapshot]) {
        if ([observer respondsToSelector:@selector(playback:needsFolderOfSheetAtURL:appending:)]) {
            [observer playback:self needsFolderOfSheetAtURL:sheetURL appending:appending];
        }
    }
}

- (void)folderSessionRestoreDidFail:(FolderSession *)session {
    [self settleLaunchOpen];
    if (_playlist.count == 0) {
        [self notifyHasNothingToRestore];
    }
}

@end
