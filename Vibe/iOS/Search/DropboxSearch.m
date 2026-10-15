//
//  DropboxSearch.m
//  Vibe (iOS)
//

#import "DropboxSearch.h"

#import "DropboxMirror.h"
#import "DropboxRules.h"
#import "PlaceholderFiles.h"

// A Dropbox query is a network round trip, so it waits for typing to pause.
static const NSTimeInterval kDropboxSearchDelay = 0.3;

@implementation DropboxSearch {
    DropboxMirror *_mirror;
    // files/search_v2's answer to _query.
    NSString *_query;
    NSArray<NSDictionary *> *_entries;
    // Stamped on each query sent; only the newest answer lands.
    uint64_t _searchGeneration;
}

- (instancetype)init {
    return [self initWithMirror:DropboxMirror.shared];
}

- (instancetype)initWithMirror:(DropboxMirror *)mirror {
    self = [super init];
    if (self) {
        _mirror = mirror;
        _entries = @[];
        _hits = @[];
        _downloaded = [NSSet set];
        _playlistPaths = [NSSet set];
    }
    return self;
}

// Only a new query asks Dropbox. The same one — a re-filter for a playlist
// change or a reappearance — re-applies the exclusion to the answer in hand.
- (void)searchQuery:(NSString *)query {
    if ([query isEqualToString:_query]) {
        _hits = [self entriesNotInPlaylist:_entries];
        return;
    }
    // Every keystroke restarts the pause and moves the generation, so an
    // answer to a query already typed past is dropped on arrival.
    [self reset];
    _query = [query copy];
    _searching = YES;
    [self performSelector:@selector(runSearch) withObject:nil afterDelay:kDropboxSearchDelay];
}

- (void)reset {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSearch) object:nil];
    _searchGeneration++;
    _searching = NO;
    _failed = NO;
    _query = nil;
    _entries = @[];
    _hits = @[];
    _downloaded = [NSSet set];
}

- (NSArray<NSDictionary *> *)entriesNotInPlaylist:(NSArray<NSDictionary *> *)entries {
    NSMutableArray<NSDictionary *> *hits = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary *entry in entries) {
        if (![_playlistPaths containsObject:entry[@"path_lower"]]) {
            [hits addObject:entry];
        }
    }
    return hits;
}

- (void)runSearch {
    uint64_t generation = _searchGeneration;
    __weak DropboxSearch *weakSelf = self;
    [_mirror searchQuery:_query
                           completion:^(NSArray<NSDictionary *> *entries, NSError *error) {
        DropboxSearch *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_searchGeneration) {
            return;
        }
        // A failure is an empty answer to this query, not a retry per
        // re-filter; the next keystroke asks again.
        if (error) {
            LogWarn(@"Dropbox: search failed: %@", error.localizedDescription);
        }
        strongSelf->_searching = NO;
        strongSelf->_failed = error != nil;
        strongSelf->_entries = entries ?: @[];
        strongSelf->_hits = [strongSelf entriesNotInPlaylist:strongSelf->_entries];
        [strongSelf notifyChange];
        [strongSelf countDownloadedEntries];
    }];
}

// Off main, a stat per file hit; the section redraws when it lands. A path
// the mirror spells another way reads as not downloaded, which errs safe.
- (void)countDownloadedEntries {
    NSArray<NSDictionary *> *entries = _entries;
    NSURL *account = _mirror.accountURL;
    uint64_t generation = _searchGeneration;
    __weak DropboxSearch *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableSet<NSString *> *downloaded = [NSMutableSet set];
        for (NSDictionary *entry in entries) {
            NSString *display = entry[@"path_display"];
            NSString *lower = entry[@"path_lower"];
            if (!account || ![display isKindOfClass:NSString.class] || ![lower isKindOfClass:NSString.class]
                    || VibeDropboxEntryKindOf(entry) == VibeDropboxEntryKindFolder) {
                continue;
            }
            NSURL *local = [account URLByAppendingPathComponent:display];
            if ([NSFileManager.defaultManager fileExistsAtPath:local.path]
                    && ![PlaceholderFiles isRemotePlaceholderFile:local]) {
                [downloaded addObject:lower];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            DropboxSearch *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_searchGeneration) {
                return;
            }
            strongSelf->_downloaded = downloaded;
            [strongSelf notifyChange];
        });
    });
}

- (void)downloadsDidChange {
    if (_entries.count > 0) {
        [self countDownloadedEntries];
    }
}

- (void)notifyChange {
    void (^handler)(void) = _changeHandler;
    if (handler) {
        handler();
    }
}

@end
