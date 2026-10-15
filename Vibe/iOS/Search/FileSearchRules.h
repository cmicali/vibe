//
//  FileSearchRules.h
//  Vibe (iOS)
//
//  What a query matches, for both of the search screen's sections, which must
//  agree where they overlap. Which sections the screen draws, and when it
//  says No Results. Then which root covers a path, for the search walk and
//  LocationStore's merge. Header-only and Foundation-only so the macOS suite
//  can test it.
//

#ifndef FileSearchRules_h
#define FileSearchRules_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - The screen's sections

// In the order they are drawn. Count is also the All scope.
typedef NS_ENUM(NSInteger, VibeSearchSection) {
    VibeSearchSectionPlaylist = 0,
    VibeSearchSectionFiles,
    VibeSearchSectionDropbox,
    VibeSearchSectionCount
};

static inline BOOL VibeSearchScopeIncludes(VibeSearchSection scope, VibeSearchSection section) {
    return scope == VibeSearchSectionCount || scope == section;
}

// The scope bar's buttons, in the order the sections are drawn: All,
// Playlist, Local, and Dropbox while linked.
static inline NSArray<NSNumber *> *VibeSearchScopeSections(BOOL dropboxLinked) {
    return dropboxLinked
            ? @[@(VibeSearchSectionCount), @(VibeSearchSectionPlaylist), @(VibeSearchSectionFiles),
                @(VibeSearchSectionDropbox)]
            : @[@(VibeSearchSectionCount), @(VibeSearchSectionPlaylist), @(VibeSearchSectionFiles)];
}

// An empty section draws no header, except a walk still running.
static inline BOOL VibeSearchShowsFilesSection(BOOL hasQuery, VibeSearchSection scope,
                                               NSUInteger hits, BOOL walking) {
    return hasQuery && VibeSearchScopeIncludes(scope, VibeSearchSectionFiles) && (hits > 0 || walking);
}

// Asking and failing both draw the section, whose heading says which.
static inline BOOL VibeSearchShowsDropboxSection(BOOL dropboxLinked, BOOL hasQuery, VibeSearchSection scope,
                                                 NSUInteger hits, BOOL searching, BOOL failed) {
    return dropboxLinked && hasQuery && VibeSearchScopeIncludes(scope, VibeSearchSectionDropbox)
            && (hits > 0 || searching || failed);
}

// No Results, once every half in scope answered with nothing. A half still
// asking, or a Dropbox failure, which says so itself, is not that. It reads
// the drawn sections, so a half out of scope cannot hold it off.
static inline BOOL VibeSearchSettledEmpty(BOOL hasQuery, NSUInteger playlistMatches, BOOL fileHitsPending,
                                          BOOL showsFiles, BOOL showsDropbox) {
    return hasQuery && playlistMatches == 0 && !fileHitsPending && !showsFiles && !showsDropbox;
}

#pragma mark - What a query matches

// Case, diacritic and width insensitive, anywhere in the text. An empty query
// matches everything, for the playlist's browse list; the files section tests
// the length itself, since a dump of a provider tree is no browse list.
static inline BOOL VibeSearchTextMatchesQuery(NSString *_Nullable text, NSString *query) {
    if (query.length == 0) {
        return YES;
    }
    if (text.length == 0) {
        return NO;
    }
    NSStringCompareOptions options =
            NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    return [text rangeOfString:query
                       options:options
                         range:NSMakeRange(0, text.length)
                        locale:NSLocale.currentLocale].location != NSNotFound;
}

// Folded once per file by the walk: folding per row per keystroke costs far
// more than the search.
static inline NSString *VibeSearchFoldedText(NSString *_Nullable text) {
    if (text.length == 0) {
        return @"";
    }
    NSStringCompareOptions options =
            NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    return [text stringByFoldingWithOptions:options locale:NSLocale.currentLocale];
}

static inline BOOL VibeSearchFoldedTextContainsQuery(NSString *foldedText,
                                                      NSString *foldedQuery) {
    return foldedQuery.length > 0
            && [foldedText rangeOfString:foldedQuery].location != NSNotFound;
}

static inline BOOL VibeSearchTrackMatchesQuery(NSString *_Nullable title,
                                               NSString *_Nullable artist,
                                               NSString *fileName,
                                               NSString *query) {
    return VibeSearchTextMatchesQuery(title, query)
            || (artist.length > 0 && VibeSearchTextMatchesQuery(artist, query))
            || VibeSearchTextMatchesQuery(fileName, query);
}

// The root IS the path or contains it. Both must be standardized; no disk. The
// separator on BOTH sides keeps "/Music" from covering "/Music Videos" while an
// exact match still counts.
static inline BOOL VibeSearchRootCoversPath(NSString *rootPath, NSString *path) {
    if (rootPath.length == 0 || path.length == 0) {
        return NO;
    }
    NSString *rootPrefix = [rootPath hasSuffix:@"/"] ? rootPath
                                                     : [rootPath stringByAppendingString:@"/"];
    NSString *pathPrefix = [path hasSuffix:@"/"] ? path : [path stringByAppendingString:@"/"];
    return [pathPrefix hasPrefix:rootPrefix];
}

// LocationStore's merge keeps roots minimal: an existing ancestor absorbs a
// candidate (an exact duplicate included), and a candidate ancestor removes
// every descendant.
static inline NSUInteger VibeSearchFolderCoveringRootIndex(
        NSArray<NSString *> *rootPaths, NSString *candidatePath) {
    for (NSUInteger index = 0; index < rootPaths.count; index++) {
        if (VibeSearchRootCoversPath(rootPaths[index], candidatePath)) {
            return index;
        }
    }
    return NSNotFound;
}

static inline NSIndexSet *VibeSearchFolderIndexesCoveredByRoot(
        NSArray<NSString *> *rootPaths, NSString *candidatePath) {
    NSMutableIndexSet *covered = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < rootPaths.count; index++) {
        if (VibeSearchRootCoversPath(candidatePath, rootPaths[index])) {
            [covered addIndex:index];
        }
    }
    return covered;
}

// A removed covering root suppresses only pending bookmarks inside it. A live
// root that now covers the bookmark is an explicit re-add and wins over that
// older removal.
static inline BOOL VibeSearchPendingRestoreShouldBeSuppressed(
        NSArray<NSString *> *suppressedRootPaths,
        NSArray<NSString *> *liveRootPaths,
        NSString *resolvedPath) {
    return VibeSearchFolderCoveringRootIndex(suppressedRootPaths, resolvedPath) != NSNotFound
            && VibeSearchFolderCoveringRootIndex(liveRootPaths, resolvedPath) == NSNotFound;
}

NS_ASSUME_NONNULL_END

#endif /* FileSearchRules_h */
