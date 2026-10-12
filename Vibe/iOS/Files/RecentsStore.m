//
//  RecentsStore.m
//  Vibe (iOS)
//

#import "RecentsStore.h"
#import "FilePaths.h"

// iOS app-layer state, so not AppSettings.
// Every file and folder opened or added, newest first: path, bookmark, folder.
static NSString *const kRecentItemsKey = @"VibeiOSRecentItems";
static const NSUInteger kMaximumRecentItems = 50;

@interface RecentsStore ()
- (instancetype)initPrivate;
@end

@implementation RecentsStore {
    // Concurrent: a stalled provider never holds another resolve back.
    dispatch_queue_t _resolveQueue;
}

+ (RecentsStore *)shared {
    static RecentsStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[RecentsStore alloc] initPrivate];
    });
    return shared;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0);
        _resolveQueue = dispatch_queue_create("RecentsStore.resolve", attributes);
    }
    return self;
}

- (NSArray<NSDictionary *> *)recentItems {
    return [NSUserDefaults.standardUserDefaults arrayForKey:kRecentItemsKey] ?: @[];
}

// Main thread. A path already listed moves to the top; picked together, the
// first picked lands on top.
- (void)recordRecentItems:(NSArray<NSDictionary *> *)items {
    NSMutableArray<NSDictionary *> *recents = [NSMutableArray arrayWithArray:items];
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    for (NSDictionary *item in items) {
        [paths addObject:item[@"path"]];
    }
    for (NSDictionary *item in self.recentItems) {
        NSString *path = [item isKindOfClass:NSDictionary.class] ? item[@"path"] : nil;
        if ([path isKindOfClass:NSString.class] && ![paths containsObject:path]) {
            [recents addObject:item];
        }
    }
    NSUInteger kept = MIN(recents.count, kMaximumRecentItems);
    [NSUserDefaults.standardUserDefaults setObject:[recents subarrayWithRange:NSMakeRange(0, kept)]
                                            forKey:kRecentItemsKey];
}

- (void)clearRecentItems {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kRecentItemsKey];
}

// A stale bookmark — the item moved or was replaced — is minted again and
// stored with where it now is, as FavoritesStore refreshes its own. Minting
// needs the scope open; the open that follows starts its own.
- (void)resolveRecentItem:(NSDictionary *)item completion:(void (^)(NSURL *))completion {
    dispatch_async(_resolveQueue, ^{
        NSData *bookmark = item[@"bookmark"];
        BOOL stale = NO;
        NSURL *url = [bookmark isKindOfClass:NSData.class]
                ? [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil
                                bookmarkDataIsStale:&stale error:NULL]
                : nil;
        NSData *refreshed = nil;
        if (url && stale) {
            BOOL scoped = [url startAccessingSecurityScopedResource];
            refreshed = [self bookmarkForURL:url];
            if (scoped) {
                [url stopAccessingSecurityScopedResource];
            }
        }
        NSString *path = item[@"path"];
        if (!url && [path isKindOfClass:NSString.class]
                && [NSFileManager.defaultManager fileExistsAtPath:path]) {
            url = [NSURL fileURLWithPath:path isDirectory:[item[@"folder"] boolValue]];
        }
        run_on_main_thread({
            if (refreshed) {
                [self replaceRecentItemAtPath:path withURL:url bookmark:refreshed];
            }
            completion(url);
        });
    });
}

// Resolve queue. Requires the scope open, which the caller holds.
- (NSData *)bookmarkForURL:(NSURL *)url {
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&error];
    if (!bookmark) {
        LogWarn(@"RecentsStore: could not bookmark %@ (%@)", url, error);
    }
    return bookmark;
}

// Main thread. In place: refreshing a bookmark is not a use.
- (void)replaceRecentItemAtPath:(NSString *)path withURL:(NSURL *)url bookmark:(NSData *)bookmark {
    NSMutableArray<NSDictionary *> *recents = [self.recentItems mutableCopy];
    for (NSUInteger i = 0; i < recents.count; i++) {
        if (![recents[i] isKindOfClass:NSDictionary.class] || ![recents[i][@"path"] isEqual:path]) {
            continue;
        }
        NSMutableDictionary *item = [recents[i] mutableCopy];
        item[@"path"] = VibeComparablePath(url.path) ?: path;
        item[@"bookmark"] = bookmark;
        recents[i] = item;
        [NSUserDefaults.standardUserDefaults setObject:recents forKey:kRecentItemsKey];
        return;
    }
}

@end
