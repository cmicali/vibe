//
//  FileSearchIndex.m
//  Vibe (iOS)
//

#import "FileSearchIndex.h"

#import <stdatomic.h>

#import "FileSearchIndexInternal.h"
#import "FileSearchRules.h"
#import "NSURLUtil.h"

// A cap, not a target: a root can be a whole Dropbox. A few megabytes here.
static const NSUInteger kMaxIndexedFiles = 20000;

// Whichever comes first. The interval gets first results up promptly on a
// provider tree, where one listing can take a second.
static const NSUInteger kFlushBatchSize = 128;
static const NSTimeInterval kFlushInterval = 0.2;

@interface FileSearchHit ()
- (instancetype)initWithURL:(NSURL *)url;
@end

@implementation FileSearchHit

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _url = url;
        _fileName = url.lastPathComponent;
        _folderName = url.URLByDeletingLastPathComponent.lastPathComponent ?: @"";
    }
    return self;
}

@end

// The path and folded text are computed once, not per row per keystroke.
@interface IndexedSearchFile : NSObject
@property (nonatomic) FileSearchHit *hit;
@property (nonatomic) NSString *path;
@property (nonatomic) NSString *foldedSearchText;
@end

@implementation IndexedSearchFile
@end

@interface FileSearchIndex ()
- (IndexedSearchFile *)indexedFileForURL:(NSURL *)url;
@end

static NSArray<NSString *> *VibeStandardizedPaths(NSArray<NSURL *> *urls) {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        [paths addObject:url.URLByStandardizingPath.path ?: @""];
    }
    return paths;
}


@implementation FileSearchIndex {
    NSArray<NSURL *>           *_roots;
    NSMutableArray<IndexedSearchFile *> *_files;
    BOOL                        _built;
    // Atomic: the walk queue reads it, main writes it.
    _Atomic(uint64_t)           _buildGeneration;
    // Atomic: the filter queue reads it, main writes it.
    _Atomic(uint64_t)           _hitRequestGeneration;
    dispatch_queue_t            _walkQueue;
    dispatch_queue_t            _filterQueue;
    // Filter queue only. Within one build generation the index only appends,
    // so an unchanged query carries its answer forward over the new suffix.
    uint64_t                    _cachedFilterBuildGeneration;
    NSString                   *_cachedFoldedQuery;
    NSSet<NSString *>          *_cachedExcludedPaths;
    NSUInteger                  _cachedFilterLimit;
    NSUInteger                  _cachedFilteredFileCount;
    NSArray<FileSearchHit *>   *_cachedFileHits;
    NSUInteger                  _lastFilterEvaluationCount;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _roots = @[];
        _files = [NSMutableArray array];
        atomic_init(&_buildGeneration, 1);
        atomic_init(&_hitRequestGeneration, 1);
        // Utility: a provider listing is the same IPC the waited-on open needs,
        // and the open outranks it (root AGENTS.md).
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _walkQueue = dispatch_queue_create("FileSearchIndex", attributes);
        dispatch_queue_attr_t filterAttributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _filterQueue = dispatch_queue_create("FileSearchIndex.filter", filterAttributes);
    }
    return self;
}

#pragma mark - Roots

- (void)setRoots:(NSArray<NSURL *> *)roots {
    NSArray<NSURL *> *pruned = [FileSearchIndex pruneNestedRoots:roots];
    if ([VibeStandardizedPaths(pruned) isEqualToArray:VibeStandardizedPaths(_roots)]) {
        return;
    }
    atomic_fetch_add(&_buildGeneration, 1);
    [self cancelPendingHitRequests];
    _roots = pruned;
    _files = [NSMutableArray array];
    _built = NO;
    _isBuilding = NO;
}

#pragma mark - Building

- (void)beginBuildIfNeeded {
    if (_built || _isBuilding || _roots.count == 0) {
        return;
    }
    _isBuilding = YES;
    NSArray<NSURL *> *roots = _roots;
    uint64_t generation = atomic_load(&_buildGeneration);
    dispatch_async(_walkQueue, ^{
        [self walkRoots:roots generation:generation];
    });
}

// Walk queue only.
- (void)walkRoots:(NSArray<NSURL *> *)roots generation:(uint64_t)generation {
    NSSet<NSString *> *supported = [NSURLUtil supportedExtensions];
    NSMutableArray<IndexedSearchFile *> *batch = [NSMutableArray arrayWithCapacity:kFlushBatchSize];
    NSTimeInterval lastFlush = CFAbsoluteTimeGetCurrent();
    NSUInteger total = 0;
    BOOL full = NO;

    for (NSURL *root in roots) {
        if (full || atomic_load(&_buildGeneration) != generation) {
            break;
        }
        NSDirectoryEnumerator<NSURL *> *walk = [NSFileManager.defaultManager
                     enumeratorAtURL:root
                  includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                     | NSDirectoryEnumerationSkipsPackageDescendants
                        errorHandler:^BOOL(NSURL *url, NSError *error) {
            // One unreadable subfolder must not end the walk.
            LogWarn(@"FileSearchIndex: skipping %@ (%@)", url.lastPathComponent, error);
            return YES;
        }];
        for (NSURL *url in walk) {
            if (atomic_load(&_buildGeneration) != generation) {
                return;
            }
            // Extension first: the directory test stats.
            if (![supported containsObject:url.pathExtension.lowercaseString]) {
                continue;
            }
            NSNumber *isDirectory = nil;
            BOOL isDir = [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL]
                    ? isDirectory.boolValue
                    : url.hasDirectoryPath;
            if (isDir) {
                continue;
            }
            [batch addObject:[self indexedFileForURL:url]];
            total++;
            if (total >= kMaxIndexedFiles) {
                LogWarn(@"FileSearchIndex: stopped at the %lu-file cap; results are partial",
                        (unsigned long)kMaxIndexedFiles);
                full = YES;
                break;
            }
            NSTimeInterval now = CFAbsoluteTimeGetCurrent();
            if (batch.count >= kFlushBatchSize || now - lastFlush >= kFlushInterval) {
                [self flushBatch:batch generation:generation];
                batch = [NSMutableArray arrayWithCapacity:kFlushBatchSize];
                lastFlush = now;
            }
        }
    }

    [self flushBatch:batch generation:generation];
    run_on_main_thread({
        if (atomic_load(&self->_buildGeneration) != generation) {
            return;
        }
        self->_isBuilding = NO;
        self->_built = YES;
        [self.delegate fileSearchIndexDidFinishBuilding:self];
    });
}

// Walk queue, or a test seam on main.
- (IndexedSearchFile *)indexedFileForURL:(NSURL *)url {
    IndexedSearchFile *file = [[IndexedSearchFile alloc] init];
    file.hit = [[FileSearchHit alloc] initWithURL:url];
    file.path = url.path ?: @"";
    NSString *searchText = [NSString stringWithFormat:@"%@\n%@",
            file.hit.fileName, file.hit.folderName ?: @""];
    file.foldedSearchText = VibeSearchFoldedText(searchText);
    return file;
}

// Walk queue only.
- (void)flushBatch:(NSArray<IndexedSearchFile *> *)batch generation:(uint64_t)generation {
    if (batch.count == 0) {
        return;
    }
    run_on_main_thread({
        if (atomic_load(&self->_buildGeneration) != generation) {
            return;
        }
        [self->_files addObjectsFromArray:batch];
        [self.delegate fileSearchIndexDidGrow:self];
    });
}

#pragma mark - Querying

- (void)requestHitsMatchingQuery:(NSString *)query
                       excluding:(NSSet<NSString *> *)excludedPaths
                           limit:(NSUInteger)limit
                      completion:(void (^)(NSArray<FileSearchHit *> *))completion {
    uint64_t generation = atomic_fetch_add(&_hitRequestGeneration, 1) + 1;
    uint64_t buildGeneration = atomic_load(&_buildGeneration);
    NSArray<IndexedSearchFile *> *files = [_files copy];
    NSString *foldedQuery = VibeSearchFoldedText(query);
    NSSet<NSString *> *excludedSnapshot = [excludedPaths copy] ?: [NSSet set];
    dispatch_async(_filterQueue, ^{
        if (atomic_load(&self->_hitRequestGeneration) != generation) {
            return;
        }
        BOOL canContinue = self->_cachedFilterBuildGeneration == buildGeneration
                && self->_cachedFilterLimit == limit
                && self->_cachedFilteredFileCount <= files.count
                && [self->_cachedFoldedQuery isEqualToString:foldedQuery]
                && [self->_cachedExcludedPaths isEqualToSet:excludedSnapshot];
        NSUInteger startIndex = canContinue ? self->_cachedFilteredFileCount : 0;
        NSMutableArray<FileSearchHit *> *hits = canContinue
                ? [self->_cachedFileHits mutableCopy]
                : [NSMutableArray arrayWithCapacity:MIN(limit, (NSUInteger)64)];
        NSUInteger evaluations = 0;
        if (foldedQuery.length > 0 && limit > 0 && hits.count < limit) {
            for (NSUInteger index = startIndex; index < files.count; index++) {
                if (atomic_load(&self->_hitRequestGeneration) != generation) {
                    return;
                }
                IndexedSearchFile *file = files[index];
                evaluations++;
                if ([excludedSnapshot containsObject:file.path]) {
                    continue;
                }
                if (!VibeSearchFoldedTextContainsQuery(
                        file.foldedSearchText, foldedQuery)) {
                    continue;
                }
                [hits addObject:file.hit];
                if (hits.count >= limit) {
                    break;
                }
            }
        }
        NSArray<FileSearchHit *> *result = [hits copy];
        self->_cachedFilterBuildGeneration = buildGeneration;
        self->_cachedFoldedQuery = foldedQuery;
        self->_cachedExcludedPaths = excludedSnapshot;
        self->_cachedFilterLimit = limit;
        self->_cachedFilteredFileCount = files.count;
        self->_cachedFileHits = result;
        self->_lastFilterEvaluationCount = evaluations;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (atomic_load(&self->_hitRequestGeneration) == generation) {
                completion(result);
            }
        });
    });
}

- (void)cancelPendingHitRequests {
    atomic_fetch_add(&_hitRequestGeneration, 1);
}

@end

// Below the main implementation: the seams touch its ivars.
@implementation FileSearchIndex (Internal)

// TRAP: prune in BOTH directions. searchRoots names the open folder before
// Documents, and a folder picked inside Documents must go; dropping only later
// roots covered by earlier ones walks that tree, and lists every file, twice.
// Hence shortest first, keeping a root only when nothing kept covers it.
+ (NSArray<NSURL *> *)pruneNestedRoots:(NSArray<NSURL *> *)roots {
    NSArray<NSURL *> *shortestFirst = [roots sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSUInteger lengthA = a.URLByStandardizingPath.path.length;
        NSUInteger lengthB = b.URLByStandardizingPath.path.length;
        if (lengthA != lengthB) {
            return lengthA < lengthB ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;   // stable
    }];
    NSMutableArray<NSURL *> *kept = [NSMutableArray arrayWithCapacity:roots.count];
    NSMutableArray<NSString *> *keptPaths = [NSMutableArray arrayWithCapacity:roots.count];
    for (NSURL *root in shortestFirst) {
        NSString *path = root.URLByStandardizingPath.path;
        if (path.length == 0) {
            continue;
        }
        BOOL covered = NO;
        for (NSString *keptPath in keptPaths) {
            if (VibeSearchRootCoversPath(keptPath, path)) {
                covered = YES;
                break;
            }
        }
        if (!covered) {
            [kept addObject:root];
            [keptPaths addObject:path];
        }
    }
    return kept;
}

- (void)appendFileURLForTesting:(NSURL *)url {
    NSParameterAssert(NSThread.isMainThread);
    [_files addObject:[self indexedFileForURL:url]];
}

- (NSUInteger)lastFilterEvaluationCountForTesting {
    __block NSUInteger count;
    dispatch_sync(_filterQueue, ^{
        count = self->_lastFilterEvaluationCount;
    });
    return count;
}

@end
