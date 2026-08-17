//
//  FolderSession.m
//  Vibe (iOS)
//

#import "FolderSession.h"
#import "DocumentTypes.h"
#import "NSURLUtil.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdatomic.h>

// NSUserDefaults keys. Kept here rather than in AppSettings: they are iOS
// app-layer state, and the shared settings file stays untouched.
static NSString *const kFolderBookmarkKey = @"VibeiOSFolderBookmark";
static NSString *const kLastTrackFileNameKey = @"VibeiOSLastTrackFileName";

@interface FolderSession () <UIDocumentPickerDelegate>
@end

@implementation FolderSession {
    // The URL whose security scope is currently open. Held for the session:
    // the player, TagLib, and the waveform loader all read files under it at
    // arbitrary later times. Main-confined, like _folderURL; the work queue
    // gets a snapshot.
    NSURL *_scopedURL;
    BOOL _scopeActive;
    NSURL *_folderURL;
    // Bookmark resolution and directory listings are file-provider IPC. Opens
    // run concurrently so a new user intent is not parked behind an older
    // provider call; openIntentGeneration decides which result may deliver.
    dispatch_queue_t _workQueue;
    _Atomic(uint64_t) _openIntentGeneration;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0);
        _workQueue = dispatch_queue_create("FolderSession", attributes);
        atomic_init(&_openIntentGeneration, 0);
    }
    return self;
}

- (void)dealloc {
    if (_scopeActive) {
        [_scopedURL stopAccessingSecurityScopedResource];
    }
}

- (NSString *)folderDisplayName {
    return _folderURL ? [[NSFileManager defaultManager] displayNameAtPath:_folderURL.path] : nil;
}

- (NSURL *)searchRoot {
    return _folderURL;
}

- (uint64_t)beginOpenIntent {
    return atomic_fetch_add_explicit(&_openIntentGeneration, 1, memory_order_acq_rel) + 1;
}

- (BOOL)isCurrentOpenIntent:(uint64_t)openIntentGeneration {
    return atomic_load_explicit(&_openIntentGeneration, memory_order_acquire)
            == openIntentGeneration;
}

#pragma mark - Picker

- (void)presentPickerFromViewController:(UIViewController *)presenter {
    NSArray<UTType *> *types = [@[UTTypeFolder] arrayByAddingObjectsFromArray:DocumentTypes.declaredFileTypes];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (url) {
        [self adoptURL:url restored:NO];
    }
}

#pragma mark - External opens

- (void)openExternalURL:(NSURL *)url openInPlace:(BOOL)openInPlace {
    if (!openInPlace) {
        // Not open-in-place: the system handed a copy in our own inbox
        // container, readable without a scope.
        uint64_t openIntentGeneration = [self beginOpenIntent];
        [self finishOpenIntent:openIntentGeneration tracks:@[url]
                     folderURL:nil selectedURL:nil restored:NO
                     scopedURL:nil scopedURLStarted:NO bookmark:nil];
        return;
    }
    [self adoptURL:url restored:NO];
}

- (void)openFileFromSearchRoots:(NSURL *)url {
    uint64_t openIntentGeneration = [self beginOpenIntent];
    NSURL *parent = url.URLByDeletingLastPathComponent;
    NSURL *sessionScopedURL = _scopeActive ? _scopedURL : nil;
    BOOL scopeHoldStarted = [sessionScopedURL startAccessingSecurityScopedResource];
    dispatch_async(_workQueue, ^{
        if (![self isCurrentOpenIntent:openIntentGeneration]) {
            if (scopeHoldStarted) {
                [sessionScopedURL stopAccessingSecurityScopedResource];
            }
            return;
        }
        // The listing is provider IPC, like every other adoption's, so it runs
        // here. No scope is started: the caller vouched that a root covers it.
        NSArray<NSURL *> *siblings = [NSURLUtil audioFilesInDirectory:parent];
        BOOL expanded = siblings.count > 0;
        if (scopeHoldStarted) {
            [sessionScopedURL stopAccessingSecurityScopedResource];
        }
        run_on_main_thread({
            [self finishOpenIntent:openIntentGeneration
                            tracks:expanded ? siblings : @[url]
                         folderURL:expanded ? parent : nil
                       selectedURL:expanded ? url : nil
                          restored:NO
                         scopedURL:sessionScopedURL
                  scopedURLStarted:NO
                          bookmark:nil];
        });
    });
}

#pragma mark - Persistence

- (BOOL)restorePersistedFolder {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kFolderBookmarkKey];
    if (!bookmark) {
        return NO;
    }
    uint64_t openIntentGeneration = [self beginOpenIntent];
    dispatch_async(_workQueue, ^{
        if (![self isCurrentOpenIntent:openIntentGeneration]) {
            return;
        }
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                               options:0
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:&error];
        if (!url) {
            LogWarn(@"FolderSession: bookmark no longer resolves (%@)", error);
            run_on_main_thread({
                if ([self isCurrentOpenIntent:openIntentGeneration]) {
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:kFolderBookmarkKey];
                    [self.delegate folderSessionRestoreDidFail:self];
                }
            });
            return;
        }
        // No pre-adopt refresh of a stale bookmark: minting bookmark data
        // needs the security scope OPEN, and adoption re-persists after the
        // scope starts anyway — the refresh before it always failed.
        [self adoptOnWorkQueue:url restored:YES sessionFolder:nil sessionScopedURL:nil
              scopeHoldStarted:NO openIntentGeneration:openIntentGeneration];
    });
    return YES;
}

- (NSString *)persistedTrackFileName {
    return [NSUserDefaults.standardUserDefaults stringForKey:kLastTrackFileNameKey];
}

- (void)setPersistedTrackFileName:(NSString *)fileName {
    if (fileName) {
        [NSUserDefaults.standardUserDefaults setObject:fileName forKey:kLastTrackFileNameKey];
    }
    else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kLastTrackFileNameKey];
    }
}

- (NSData *)bookmarkForURL:(NSURL *)url {
    // iOS has no WithSecurityScope option: a default bookmark of a
    // picker-granted URL round-trips the scope by itself. Requires the URL's
    // scope to be open, which every caller guarantees.
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&error];
    if (!bookmark) {
        LogWarn(@"FolderSession: could not bookmark %@ (%@)", url, error);
    }
    return bookmark;
}

#pragma mark - Adoption

// The one funnel for a URL from any source. Each request owns an intent number;
// provider work can overlap, but only the newest result may replace the live
// session. The caller also takes a temporary claim on the current scope so an
// older worker can finish safely after a newer result replaces that scope.
- (void)adoptURL:(NSURL *)url restored:(BOOL)restored {
    uint64_t openIntentGeneration = [self beginOpenIntent];
    NSURL *sessionFolder = _folderURL;
    NSURL *sessionScopedURL = _scopeActive ? _scopedURL : nil;
    BOOL scopeHoldStarted = [sessionScopedURL startAccessingSecurityScopedResource];
    dispatch_async(_workQueue, ^{
        [self adoptOnWorkQueue:url restored:restored
                 sessionFolder:sessionFolder sessionScopedURL:sessionScopedURL
              scopeHoldStarted:scopeHoldStarted
          openIntentGeneration:openIntentGeneration];
    });
}

- (void)adoptOnWorkQueue:(NSURL *)url
                restored:(BOOL)restored
           sessionFolder:(NSURL *)sessionFolder
         sessionScopedURL:(NSURL *)sessionScopedURL
         scopeHoldStarted:(BOOL)scopeHoldStarted
     openIntentGeneration:(uint64_t)openIntentGeneration {
    if (![self isCurrentOpenIntent:openIntentGeneration]) {
        if (scopeHoldStarted) {
            [sessionScopedURL stopAccessingSecurityScopedResource];
        }
        return;
    }
    // A NO return is not failure: the app's own container and open-in-place
    // inbox URLs are not security-scoped. Track what we actually started so
    // the paired stop is balanced.
    BOOL scoped = [url startAccessingSecurityScopedResource];

    NSNumber *isDirectory = nil;
    [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
    // The key can be absent — a URL the provider has not resolved yet — and
    // then the trailing slash is all there is to go on. Compared to nil
    // explicitly: an NSNumber * in a boolean position is a pointer test, not
    // a value test, which is what the analyzer flags.
    BOOL isDir = isDirectory != nil ? isDirectory.boolValue : url.hasDirectoryPath;

    NSArray<NSURL *> *tracks;
    NSURL *folderURL = nil;
    NSURL *selectedURL = nil;
    if (isDir) {
        tracks = [NSURLUtil audioFilesInDirectory:url];
        folderURL = url;
        if (tracks.count == 0) {
            if (scoped) {
                [url stopAccessingSecurityScopedResource];
            }
            if (scopeHoldStarted) {
                [sessionScopedURL stopAccessingSecurityScopedResource];
            }
            run_on_main_thread({
                if ([self isCurrentOpenIntent:openIntentGeneration]) {
                    if (restored) {
                        [self.delegate folderSessionRestoreDidFail:self];
                    }
                    else {
                        [self.delegate folderSessionDidOpenEmptyFolder:self];
                    }
                }
            });
            return;
        }
    }
    else {
        // A single-file grant reaches only that file — iOS grants no sibling
        // access — but a FOLDER grant already in hand may cover it: the live
        // session folder, or the persisted bookmark on a cold open-in-place.
        // Then "tap a file in Dropbox" expands back into the
        // directory-as-playlist model, with the tapped file selected. Only a
        // file in a never-granted folder stays a one-track playlist.
        BOOL grantScopeStarted = NO;
        NSURL *granted = [self grantedFolderCoveringFileURL:url
                                              sessionFolder:sessionFolder
                                               startedScope:&grantScopeStarted];
        if (granted) {
            NSArray<NSURL *> *siblings = [NSURLUtil audioFilesInDirectory:granted];
            if (siblings.count > 0) {
                if (scoped) {
                    [url stopAccessingSecurityScopedResource]; // the folder grant covers it
                }
                NSURL *scopedURL = grantScopeStarted ? granted : sessionScopedURL;
                NSData *bookmark = [self isCurrentOpenIntent:openIntentGeneration]
                        ? [self bookmarkForURL:granted]
                        : nil;
                if (scopeHoldStarted) {
                    [sessionScopedURL stopAccessingSecurityScopedResource];
                }
                run_on_main_thread({
                    [self finishOpenIntent:openIntentGeneration tracks:siblings
                                 folderURL:granted selectedURL:url restored:restored
                                 scopedURL:scopedURL
                          scopedURLStarted:grantScopeStarted
                                  bookmark:bookmark];
                });
                return;
            }
            if (grantScopeStarted) {
                [granted stopAccessingSecurityScopedResource];
            }
        }
        tracks = @[url];
    }

    NSURL *scopedURL = scoped ? url : nil;
    // A one-file open never replaces a folder bookmark: that broader grant is
    // what powers sibling expansion and relaunch restore.
    BOOL shouldPersist = isDir || ![self persistedBookmarkIsFolder];
    NSData *bookmark = shouldPersist && [self isCurrentOpenIntent:openIntentGeneration]
            ? [self bookmarkForURL:url]
            : nil;
    if (scopeHoldStarted) {
        [sessionScopedURL stopAccessingSecurityScopedResource];
    }
    run_on_main_thread({
        [self finishOpenIntent:openIntentGeneration tracks:tracks
                     folderURL:folderURL selectedURL:selectedURL restored:restored
                     scopedURL:scopedURL scopedURLStarted:scoped bookmark:bookmark];
    });
}

- (BOOL)persistedBookmarkIsFolder {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kFolderBookmarkKey];
    if (!bookmark) {
        return NO;
    }
    BOOL stale = NO;
    NSURL *resolved = [NSURL URLByResolvingBookmarkData:bookmark
                                                options:0
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&stale
                                                  error:NULL];
    NSNumber *isDirectory = nil;
    [resolved getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
    return isDirectory.boolValue;
}

// The folder grant covering url's DIRECT parent, or nil: first the caller's
// snapshot of the live session folder (its scope is already open), then the
// persisted bookmark — a cold-start "Open in Vibe" arrives before any
// restore ran. Paths are compared standardized; a match through the bookmark
// starts that folder's scope and reports it via startedScope so the caller
// can hand ownership to the winning intent or release a stale one.
- (NSURL *)grantedFolderCoveringFileURL:(NSURL *)url
                          sessionFolder:(NSURL *)sessionFolder
                           startedScope:(BOOL *)startedScope {
    *startedScope = NO;
    NSString *parent = url.URLByStandardizingPath.URLByDeletingLastPathComponent.path;
    if (sessionFolder && [parent isEqualToString:sessionFolder.URLByStandardizingPath.path]) {
        return sessionFolder;
    }
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kFolderBookmarkKey];
    if (!bookmark) {
        return nil;
    }
    BOOL stale = NO;
    NSURL *resolved = [NSURL URLByResolvingBookmarkData:bookmark
                                                options:0
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&stale
                                                  error:NULL];
    if (!resolved || ![parent isEqualToString:resolved.URLByStandardizingPath.path]) {
        return nil;
    }
    *startedScope = [resolved startAccessingSecurityScopedResource];
    return resolved;
}

// Main thread only. A stale request releases only the new scope it started;
// the current session stays untouched. Bookmark persistence is here too, under
// the same intent check, so late provider work cannot overwrite a newer open.
- (void)finishOpenIntent:(uint64_t)openIntentGeneration
                   tracks:(NSArray<NSURL *> *)tracks
                folderURL:(NSURL *)folderURL
              selectedURL:(NSURL *)selectedURL
                 restored:(BOOL)restored
                scopedURL:(NSURL *)scopedURL
         scopedURLStarted:(BOOL)scopedURLStarted
                 bookmark:(NSData *)bookmark {
    if (![self isCurrentOpenIntent:openIntentGeneration]) {
        if (scopedURLStarted) {
            [scopedURL stopAccessingSecurityScopedResource];
        }
        return;
    }
    if (bookmark) {
        [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kFolderBookmarkKey];
    }
    // Release the previous grant only after the new one is in hand, so a
    // failed pick never strands the current playlist unreadable.
    // A request that started a fresh claim replaces the previous one even when
    // both NSURL pointers happen to be identical; otherwise that claim leaks.
    if (_scopeActive && (_scopedURL != scopedURL || scopedURLStarted)) {
        [_scopedURL stopAccessingSecurityScopedResource];
    }
    _scopedURL = scopedURL;
    _scopeActive = (scopedURL != nil);
    _folderURL = folderURL;
    [self.delegate folderSession:self didOpenTracks:tracks folderURL:folderURL
                     selectedURL:selectedURL restored:restored];
}

@end
