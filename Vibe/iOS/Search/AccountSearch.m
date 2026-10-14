//
//  AccountSearch.m
//  Vibe (iOS)
//

#import "AccountSearch.h"

#import "AccountMirror.h"

// A service's query is a network round trip, so it waits for typing to pause.
static const NSTimeInterval kAccountSearchDelay = 0.3;

@implementation AccountSearch {
    // The service's answer to _query.
    NSString *_query;
    NSArray<NSDictionary *> *_entries;
    // Stamped on each query sent; only the newest answer lands.
    uint64_t _searchGeneration;
}

- (instancetype)initWithMirror:(AccountMirror *)mirror {
    self = [super init];
    if (self) {
        _mirror = mirror;
        _entries = @[];
        _hits = @[];
        _downloaded = [NSSet set];
        _playlistIdentities = [NSSet set];
    }
    return self;
}

// Only a new query asks the service. The same one — a re-filter for a
// playlist change or a reappearance — re-applies the exclusion to the answer
// in hand.
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
    [self performSelector:@selector(runSearch) withObject:nil afterDelay:kAccountSearchDelay];
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
        NSString *identity = [_mirror identityOfEntry:entry];
        if (!identity || ![_playlistIdentities containsObject:identity]) {
            [hits addObject:entry];
        }
    }
    return hits;
}

- (void)runSearch {
    uint64_t generation = _searchGeneration;
    __weak AccountSearch *weakSelf = self;
    AccountMirror *mirror = _mirror;
    [mirror searchQuery:_query completion:^(NSArray<NSDictionary *> *entries, NSError *error) {
        AccountSearch *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_searchGeneration) {
            return;
        }
        // A failure is an empty answer to this query, not a retry per
        // re-filter; the next keystroke asks again.
        if (error) {
            LogWarn(@"%@: search failed: %@", mirror.serviceName, error.localizedDescription);
        }
        strongSelf->_searching = NO;
        strongSelf->_failed = error != nil;
        strongSelf->_entries = entries ?: @[];
        strongSelf->_hits = [strongSelf entriesNotInPlaylist:strongSelf->_entries];
        [strongSelf notifyChange];
        [strongSelf countDownloadedEntries];
    }];
}

// Off main; the section redraws when it lands.
- (void)countDownloadedEntries {
    uint64_t generation = _searchGeneration;
    __weak AccountSearch *weakSelf = self;
    [_mirror downloadedIdentitiesOfEntries:_entries completion:^(NSSet<NSString *> *identities) {
        AccountSearch *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_searchGeneration) {
            return;
        }
        strongSelf->_downloaded = identities;
        [strongSelf notifyChange];
    }];
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
