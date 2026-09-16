//
//  FileSearchRules.h
//  Vibe (iOS)
//
//  What a search query matches, in the one place both of the search screen's
//  sections read it. The playlist section matches tags, the files section
//  matches path components, and they must agree wherever they overlap: a
//  filename that matched in one and not the other reads as a broken walk
//  rather than as two comparisons that drifted apart.
//
//  Header-only and Foundation-only so the macOS suite can test it.
//

#ifndef FileSearchRules_h
#define FileSearchRules_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Case, diacritic and width insensitive, matching anywhere in the text — a
// query is a fragment the user half-remembers, not a prefix.
//
// An empty query is no constraint and matches everything: the playlist section
// doubles as a browse list. The FILES section does not use that reading — an
// empty query there means "walk nothing", since a recursive dump of a provider
// tree is not a browse list — so it tests the length itself.
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

// FileSearchIndex prepares these strings once as the directory walk discovers
// them. Repeating locale-aware folding for every indexed row on every
// keystroke is substantially more work than the substring search itself.
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

// A track whose tags are loaded is named by them, with the filename as the
// fallback the rest of the app already uses for an untagged file.
static inline BOOL VibeSearchTrackMatchesQuery(NSString *_Nullable title,
                                               NSString *_Nullable artist,
                                               NSString *fileName,
                                               NSString *query) {
    return VibeSearchTextMatchesQuery(title, query)
            || (artist.length > 0 && VibeSearchTextMatchesQuery(artist, query))
            || VibeSearchTextMatchesQuery(fileName, query);
}

// A file the walk found has no tags — reading them would be a download each —
// so it is named by its path. The containing folder counts, because on a music
// tree that folder is the album or the artist and a query for it is how a whole
// directory of tracks named nothing like it gets found.
static inline BOOL VibeSearchFileMatchesQuery(NSString *fileName,
                                              NSString *_Nullable folderName,
                                              NSString *query) {
    if (query.length == 0) {
        return NO;
    }
    return VibeSearchTextMatchesQuery(fileName, query)
            || (folderName.length > 0 && VibeSearchTextMatchesQuery(folderName, query));
}

// Whether one search root already covers a path — it IS it, or contains it. A
// folder grant reaches the whole subtree, so a root inside another root buys
// nothing and walking both would list every file under it twice.
//
// Both paths must already be standardized; this is string work and touches no
// disk. The separator is appended to BOTH sides so "/Music" cannot be read as
// covering "/Music Videos", and so an exact match still counts.
static inline BOOL VibeSearchRootCoversPath(NSString *rootPath, NSString *path) {
    if (rootPath.length == 0 || path.length == 0) {
        return NO;
    }
    NSString *rootPrefix = [rootPath hasSuffix:@"/"] ? rootPath
                                                     : [rootPath stringByAppendingString:@"/"];
    NSString *pathPrefix = [path hasSuffix:@"/"] ? path : [path stringByAppendingString:@"/"];
    return [pathPrefix hasPrefix:rootPrefix];
}

// The two halves of SearchFolderStore's one merge. Existing roots are kept
// minimal: an ancestor absorbs a candidate, while a candidate ancestor removes
// every descendant. Exact duplicates take the first path and are absorbed.
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
