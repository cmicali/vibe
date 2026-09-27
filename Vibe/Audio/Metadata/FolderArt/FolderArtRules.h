//
//  FolderArtRules.h
//  Vibe
//
//  What a cover may be called and which name wins, shared by the resolver and
//  NSURLUtil's folder walk.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Where a cover is looked for

// Beside the audio file only, never a parent: accepted cost, Album/CD1 misses
// Album/cover.jpg. Any depth is arbitrary, and a Music folder's stray cover
// would become a whole library's art.

#pragma mark - What a cover is called

// Candidates worth a blind stat (a lone file, no listing); the rest match only
// against a listing.
static const NSUInteger kVibeFolderArtStatProbeCount = 3;

// Best first: .jpg for every stem before any .png, since a folder holding
// both usually got the .jpg from the ripper. The stems are the ecosystem's
// (Picard, beets, WMP, foobar2000, Plex). Absent on purpose: `thumb` (too
// small), `poster` and `default` (video conventions), AlbumArt_{GUID}_*.jpg
// (needs prefix matching). Lower case: a stat on a case-insensitive volume
// finds Cover.JPG, and VibeFolderArtCandidateRank folds case for listings.
static inline NSArray<NSString *> *VibeFolderArtCandidateFilenames(void) {
    static NSArray<NSString *> *candidates;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        candidates = @[
            @"cover.jpg", @"folder.jpg", @"album.jpg",   // the stat probes
            @"front.jpg", @"albumart.jpg", @"art.jpg",
            @"cover.png", @"folder.png", @"album.png",
            @"front.png", @"albumart.png", @"art.png",
            @"cover.jpeg", @"folder.jpeg", @"album.jpeg",
            @"front.jpeg", @"albumart.jpeg", @"art.jpeg",
            @"cover.webp", @"folder.webp", @"album.webp",
            @"front.webp", @"albumart.webp", @"art.webp",
        ];
    });
    return candidates;
}

// NSNotFound when not a cover. Case-insensitive, whole-name: scan-cover.jpg
// is not a cover.
static inline NSUInteger VibeFolderArtCandidateRank(NSString *_Nullable filename) {
    static NSDictionary<NSString *, NSNumber *> *ranks;
    static NSUInteger longestCandidate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *candidates = VibeFolderArtCandidateFilenames();
        NSMutableDictionary<NSString *, NSNumber *> *byName =
                [NSMutableDictionary dictionaryWithCapacity:candidates.count];
        NSUInteger longest = 0;
        for (NSUInteger index = 0; index < candidates.count; index++) {
            NSString *name = candidates[index];
            byName[name] = @(index);
            longest = MAX(longest, name.length);
        }
        ranks = byName;
        longestCandidate = longest;
    });
    // Length first rejects nearly every entry of a dropped folder without
    // allocating a lower-cased copy.
    if (filename.length == 0 || filename.length > longestCandidate) {
        return NSNotFound;
    }
    NSNumber *rank = ranks[filename.lowercaseString];
    return rank != nil ? rank.unsignedIntegerValue : NSNotFound;
}

// NSNotFound is "not a cover" on the left and "nothing yet" on the right. It
// is NSIntegerMax, not NSUIntegerMax, so it must be tested, not compared.
static inline BOOL VibeFolderArtRankBeats(NSUInteger rank, NSUInteger incumbentRank) {
    if (rank == NSNotFound) {
        return NO;
    }
    return incumbentRank == NSNotFound || rank < incumbentRank;
}

// Returns the caller's own spelling, which is what must be opened.
static inline NSString *_Nullable VibeFolderArtBestCandidate(NSArray<NSString *> *_Nullable filenames) {
    NSString *best = nil;
    NSUInteger bestRank = NSNotFound;
    for (NSString *filename in filenames) {
        NSUInteger rank = VibeFolderArtCandidateRank(filename);
        if (VibeFolderArtRankBeats(rank, bestRank)) {
            bestRank = rank;
            best = filename;
        }
    }
    return best;
}

// The streaming form for a tree walk: the best cover so far per directory.
static inline void VibeFolderArtNoteCandidate(NSString *_Nullable directory,
                                              NSString *_Nullable filename,
                                              NSMutableDictionary<NSString *, NSString *> *artByDirectory,
                                              NSMutableDictionary<NSString *, NSNumber *> *rankByDirectory) {
    NSUInteger rank = VibeFolderArtCandidateRank(filename);
    if (rank == NSNotFound || directory.length == 0) {
        return;
    }
    NSNumber *incumbent = rankByDirectory[directory];
    if (!VibeFolderArtRankBeats(rank, incumbent != nil ? incumbent.unsignedIntegerValue : NSNotFound)) {
        return;
    }
    rankByDirectory[directory] = @(rank);
    artByDirectory[directory] = filename;
}

NS_ASSUME_NONNULL_END
