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
    // arbitrary later times.
    NSURL *_scopedURL;
    BOOL _scopeActive;
    NSURL *_folderURL;
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
    BOOL stale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                           options:0
                                     relativeToURL:nil
                               bookmarkDataIsStale:&stale
                                             error:&error];
    if (!url) {
        LogWarn(@"FolderSession: bookmark no longer resolves (%@)", error);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kFolderBookmarkKey];
        return NO;
    }
    if (stale) {
        [self persistBookmarkForURL:url];
    }
    return [self adoptURL:url restored:YES];
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
    // picker-granted URL round-trips the scope by itself.
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

// The one funnel for a URL from any source: opens its scope, lists it if it
// is a folder, persists it, and delivers. Returns NO when nothing playable
// came of it (the delegate hears folderSessionDidOpenEmptyFolder: only for a
// genuinely empty folder pick, not a failed restore).
- (BOOL)adoptURL:(NSURL *)url restored:(BOOL)restored {
    // A NO return is not failure: the app's own container and open-in-place
    // inbox URLs are not security-scoped. Track what we actually started so
    // the paired stop is balanced.
    BOOL scoped = [url startAccessingSecurityScopedResource];

    NSNumber *isDirectory = nil;
    [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
    BOOL isDir = isDirectory.boolValue || (!isDirectory && url.hasDirectoryPath);

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
            if (!restored) {
                [self.delegate folderSessionDidOpenEmptyFolder:self];
            }
            return NO;
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
                                          startedScope:&grantScopeStarted];
        if (granted) {
            NSArray<NSURL *> *siblings = [NSURLUtil audioFilesInDirectory:granted];
            if (siblings.count > 0) {
                if (scoped) {
                    [url stopAccessingSecurityScopedResource]; // the folder grant covers it
                }
                [self deliverTracks:siblings
                          folderURL:granted
                        selectedURL:url
                           restored:restored
                          scopedURL:(grantScopeStarted ? granted
                                     : (_scopeActive ? _scopedURL : nil))];
                [self persistBookmarkForURL:granted];
                return YES;
            }
            if (grantScopeStarted) {
                [granted stopAccessingSecurityScopedResource];
            }
        }
        tracks = @[url];
    }

    [self deliverTracks:tracks folderURL:folderURL selectedURL:selectedURL
               restored:restored scopedURL:(scoped ? url : nil)];
    // A one-track file open must not clobber a FOLDER bookmark: the folder
    // grant is what powers file-pick expansion and the relaunch restore, and
    // a stray single file is worth less than either.
    if (isDir || ![self persistedBookmarkIsFolder]) {
        [self persistBookmarkForURL:url];
    }
    return YES;
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

// The folder grant covering url's DIRECT parent, or nil: first the live
// session folder (its scope is already open), then the persisted bookmark —
// a cold-start "Open in Vibe" arrives before any restore ran. Paths are
// compared standardized; a match through the bookmark starts that folder's
// scope and reports it via startedScope so the caller hands it to
// deliverTracks for the balanced release.
- (NSURL *)grantedFolderCoveringFileURL:(NSURL *)url startedScope:(BOOL *)startedScope {
    *startedScope = NO;
    NSString *parent = url.URLByStandardizingPath.URLByDeletingLastPathComponent.path;
    if (_folderURL && [parent isEqualToString:_folderURL.URLByStandardizingPath.path]) {
        return _folderURL;
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
