//
//  FolderSession.m
//  Vibe (iOS)
//

#import "FolderSession.h"
#import "DocumentTypes.h"
#import "NSURLUtil.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
    // Bookmark resolution and the directory listing are file-provider IPC —
    // seconds on a large cloud folder — so adoption runs here, serially (so
    // overlapping opens deliver in submission order), and only the delegate
    // delivery returns to main.
    dispatch_queue_t _workQueue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _workQueue = dispatch_queue_create("FolderSession", attributes);
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
        [self deliverTracks:@[url] folderURL:nil selectedURL:nil restored:NO scopedURL:nil];
        return;
    }
    [self adoptURL:url restored:NO];
}

#pragma mark - Persistence

- (BOOL)restorePersistedFolder {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kFolderBookmarkKey];
    if (!bookmark) {
        return NO;
    }
    dispatch_async(_workQueue, ^{
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
                [NSUserDefaults.standardUserDefaults removeObjectForKey:kFolderBookmarkKey];
                [self.delegate folderSessionRestoreDidFail:self];
            });
            return;
        }
        // No pre-adopt refresh of a stale bookmark: minting bookmark data
        // needs the security scope OPEN, and adoption re-persists after the
        // scope starts anyway — the refresh before it always failed.
        [self adoptOnWorkQueue:url restored:YES sessionFolder:nil sessionScopedURL:nil];
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

- (void)persistBookmarkForURL:(NSURL *)url {
    // iOS has no WithSecurityScope option: a default bookmark of a
    // picker-granted URL round-trips the scope by itself. Requires the URL's
    // scope to be open, which every caller guarantees.
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&error];
    if (bookmark) {
        [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kFolderBookmarkKey];
    }
    else {
        LogWarn(@"FolderSession: could not bookmark %@ (%@)", url, error);
    }
}

#pragma mark - Adoption

// The one funnel for a URL from any source. The scope open, the listing, and
// the bookmark work all happen on the work queue; only delivery lands on
// main. The caller snapshots the main-confined session state, because a
// file-pick expansion consults the live folder grant.
- (void)adoptURL:(NSURL *)url restored:(BOOL)restored {
    NSURL *sessionFolder = _folderURL;
    NSURL *sessionScopedURL = _scopeActive ? _scopedURL : nil;
    dispatch_async(_workQueue, ^{
        [self adoptOnWorkQueue:url restored:restored
                 sessionFolder:sessionFolder sessionScopedURL:sessionScopedURL];
    });
}

- (void)adoptOnWorkQueue:(NSURL *)url
                restored:(BOOL)restored
           sessionFolder:(NSURL *)sessionFolder
        sessionScopedURL:(NSURL *)sessionScopedURL {
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
            run_on_main_thread({
                if (restored) {
                    [self.delegate folderSessionRestoreDidFail:self];
                }
                else {
                    [self.delegate folderSessionDidOpenEmptyFolder:self];
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
                run_on_main_thread({
                    [self deliverTracks:siblings folderURL:granted selectedURL:url
                               restored:restored scopedURL:scopedURL];
                });
                [self persistBookmarkForURL:granted];
                return;
            }
            if (grantScopeStarted) {
                [granted stopAccessingSecurityScopedResource];
            }
        }
        tracks = @[url];
    }

    NSURL *scopedURL = scoped ? url : nil;
    run_on_main_thread({
        [self deliverTracks:tracks folderURL:folderURL selectedURL:selectedURL
                   restored:restored scopedURL:scopedURL];
    });
    // A one-track file open must not clobber a FOLDER bookmark: the folder
    // grant is what powers file-pick expansion and the relaunch restore, and
    // a stray single file is worth less than either. Persisting here, after
    // the scope opened, is also what refreshes a stale bookmark.
    if (isDir || ![self persistedBookmarkIsFolder]) {
        [self persistBookmarkForURL:url];
    }
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
// hands it to deliverTracks for the balanced release.
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

// Main thread only: the session state is main-confined, and the delegate is
// the UI.
- (void)deliverTracks:(NSArray<NSURL *> *)tracks
            folderURL:(NSURL *)folderURL
          selectedURL:(NSURL *)selectedURL
             restored:(BOOL)restored
            scopedURL:(NSURL *)scopedURL {
    // Release the previous grant only after the new one is in hand, so a
    // failed pick never strands the current playlist unreadable.
    if (_scopeActive && _scopedURL != scopedURL) {
        [_scopedURL stopAccessingSecurityScopedResource];
    }
    _scopedURL = scopedURL;
    _scopeActive = (scopedURL != nil);
    _folderURL = folderURL;
    [self.delegate folderSession:self didOpenTracks:tracks folderURL:folderURL
                     selectedURL:selectedURL restored:restored];
}

@end
