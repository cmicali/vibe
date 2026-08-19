//
//  FolderArtRules.h
//  Vibe
//
//  What a cover beside an audio file may be called, and which name wins.
//  FolderArtResolver applies these rules to real folders; NSURLUtil's folder
//  walk applies the same matching to entries it is already visiting.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Where a cover is looked for

// **Beside the audio file, and only beside it.** No parent is consulted, ever.
// Known cost, accepted: a multi-disc album with Album/cover.jpg and audio in
// Album/CD1 shows no art. Walking up would have to pick a depth — one level is
// arbitrary, more turns a Music folder's stray cover.jpg into a whole library's
// artwork — and costs a probe per level on folders that mostly have nothing.

#pragma mark - What a cover is called

// How many candidates are worth a stat when there is no directory listing in
// hand — one file opened on its own. The list is ordered so these three are the
// spellings actually found in the wild; the rest are only matched against a
// listing, where they cost nothing.
static const NSUInteger kVibeFolderArtStatProbeCount = 3;

// Best first, ordered by how common the spelling is: .jpg for every stem before
// any .png, because a folder holding both cover.png and folder.jpg almost
// always got the .png from a download and the .jpg from the ripper that wrote
// the audio.
//
// The six stems are what the ecosystem agrees on: `cover` (Picard, beets),
// `folder` (Windows Media Player, Explorer), `front` and `album` (foobar2000),
// `albumart` (Plex, Navidrome), `art` (beets' fallback). Deliberately absent:
// `thumb`, small by definition and soft at the 1024px header size; `poster` and
// `default`, video-library conventions that match unrelated images here; and
// AlbumArt_{GUID}_Large.jpg, which needs prefix matching this whole-name rule
// does not do.
//
// Lower case only. macOS volumes are case-insensitive by default, so a stat for
// cover.jpg finds Cover.JPG; a listing goes through VibeFolderArtCandidateRank,
// which folds case explicitly.
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

// Where this filename sits in the list above, or NSNotFound when it is not a
// cover. Case-insensitive, and matches the *whole* name, so scan-cover.jpg and
// folder art.png are not covers.
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
    // Length first: free, and it rejects essentially every filename in a music
    // folder without allocating the lower-cased copy the lookup needs. This
    // runs on every entry of a dropped folder.
    if (filename.length == 0 || filename.length > longestCandidate) {
        return NSNotFound;
    }
    NSNumber *rank = ranks[filename.lowercaseString];
    return rank != nil ? rank.unsignedIntegerValue : NSNotFound;
}

// The one comparison every caller makes, so "a better cover" cannot come to
// mean two things. NSNotFound means "not a cover" on the left and "nothing yet"
// on the right — and it is NSIntegerMax, not NSUIntegerMax, so it must be
// tested rather than compared.
static inline BOOL VibeFolderArtRankBeats(NSUInteger rank, NSUInteger incumbentRank) {
    if (rank == NSNotFound) {
        return NO;
    }
    return incumbentRank == NSNotFound || rank < incumbentRank;
}

// The cover among a directory's filenames, or nil when it holds none. Returns
// the caller's own spelling, since that is what has to be opened.
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

// The streaming form, for a caller walking a tree entry by entry rather than
// holding one directory's listing: keeps the best cover seen so far per
// directory, in the two dictionaries it is given.
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
