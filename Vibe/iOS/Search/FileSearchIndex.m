//
//  FileSearchIndex.m
//  Vibe (iOS)
//

#import "FileSearchIndex.h"

#import <stdatomic.h>

#import "FilePaths.h"
#import "FileSearchIndexInternal.h"
#import "FileSearchRules.h"
#import "FolderWalk.h"
#import "PlaylistEntry.h"

// Bound memory when a granted root contains a large library.
static const NSUInteger kMaxIndexedFiles = 20000;

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

static NSArray<NSString *> *VibeComparablePaths(NSArray<NSURL *> *urls) {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        [paths addObject:VibeComparablePath(url.path) ?: @""];
    }
    return paths;
}


@implementation FileSearchIndex {
    NSArray<NSURL *>           *_roots;
    NSMutableArray<IndexedSearchFile *> *_files;
    BOOL                        _built;
    // Main only. The token of the walk that fills _files, cancelled when the
    // roots change. A delivery from any other walk is dropped.
    NSProgress                 *_buildProgress;
    // Atomic: the filter queue reads it, main writes it.
    _Atomic(uint64_t)           _hitRequestGeneration;
    dispatch_queue_t            _filterQueue;
    // Filter queue only. Within one walk the index only appends, so an
    // unchanged query carries its answer forward over the new suffix.
    NSProgress                 *_cachedFilterBuild;
    NSString                   *_cachedFoldedQuery;
    NSSet<NSString *>          *_cachedExcludedPaths;
    NSUInteger                  _cachedFilterLimit;
    NSUInteger                  _cachedFilteredFileCount;
    NSArray<FileSearchHit *>   *_cachedFileHits;
#if DEBUG
    NSUInteger                  _lastFilterEvaluationCount;
#endif
    // kMaxIndexedFiles, unless a test set a smaller cap.
    NSUInteger                  _maxIndexedFiles;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _roots = @[];
        _files = [NSMutableArray array];
        _maxIndexedFiles = kMaxIndexedFiles;
        atomic_init(&_hitRequestGeneration, 1);
        dispatch_queue_attr_t filterAttributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _filterQueue = dispatch_queue_create("FileSearchIndex.filter", filterAttributes);
    }
    return self;
}

#pragma mark - Roots

- (void)setRoots:(NSArray<NSURL *> *)roots {
    NSArray<NSURL *> *pruned = [FileSearchIndex pruneNestedRoots:roots];
    if ([VibeComparablePaths(pruned) isEqualToArray:VibeComparablePaths(_roots)]) {
        return;
    }
    [_buildProgress cancel];
    _buildProgress = nil;
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
    NSProgress *progress = [NSProgress discreteProgressWithTotalUnitCount:-1];
    _buildProgress = progress;
    NSSet<NSString *> *supported = [FolderWalk supportedExtensions];
    NSUInteger cap = _maxIndexedFiles;
    // The batches arrive one at a time on one worker.
    __block NSUInteger total = 0;
    [FolderWalk scanRoots:_roots readPolicy:VibeFolderScanReadPolicyNone progress:progress
                    batch:^(NSArray<PlaylistEntry *> *entries) {
        NSMutableArray<IndexedSearchFile *> *batch = [NSMutableArray arrayWithCapacity:entries.count];
        for (PlaylistEntry *entry in entries) {
            // A CUE sheet arrives as a file. Only audio is a hit.
            if (total < cap && [supported containsObject:entry.url.pathExtension.lowercaseString]) {
                [batch addObject:[self indexedFileForURL:entry.url]];
                total++;
            }
        }
        [self flushBatch:batch progress:progress];
        if (total >= cap && !progress.isCancelled) {
            LogWarn(@"FileSearchIndex: stopped at the %lu-file cap; results are partial", (unsigned long)cap);
            [progress cancel];
        }
    } completion:^(NSArray<NSNumber *> *verdicts, NSArray<NSArray<NSError *> *> *failures) {
        run_on_main_thread({
            if (self->_buildProgress != progress) {
                return;
            }
            self->_isBuilding = NO;
            self->_built = YES;
            [self.delegate fileSearchIndexDidFinishBuilding:self];
        });
    }];
}

// The scan's worker, or a test seam on main.
- (IndexedSearchFile *)indexedFileForURL:(NSURL *)url {
    IndexedSearchFile *file = [[IndexedSearchFile alloc] init];
    file.hit = [[FileSearchHit alloc] initWithURL:url];
    // The scan resolves its roots, so a hit under /var is spelled
    // /private/var. The exclusion set is in this spelling too.
    file.path = VibeComparablePath(url.path) ?: @"";
    NSString *searchText = [NSString stringWithFormat:@"%@\n%@",
            file.hit.fileName, file.hit.folderName ?: @""];
    file.foldedSearchText = VibeSearchFoldedText(searchText);
    return file;
}

// The scan's worker only.
- (void)flushBatch:(NSArray<IndexedSearchFile *> *)batch progress:(NSProgress *)progress {
    if (batch.count == 0) {
        return;
    }
    run_on_main_thread({
        if (self->_buildProgress != progress) {
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
    NSProgress *build = _buildProgress;
    NSArray<IndexedSearchFile *> *files = [_files copy];
    NSString *foldedQuery = VibeSearchFoldedText(query);
    NSSet<NSString *> *excludedSnapshot = [excludedPaths copy] ?: [NSSet set];
    dispatch_async(_filterQueue, ^{
        if (atomic_load(&self->_hitRequestGeneration) != generation) {
            return;
        }
        BOOL canContinue = self->_cachedFilterBuild == build
                && self->_cachedFilterLimit == limit
                && self->_cachedFilteredFileCount <= files.count
                && [self->_cachedFoldedQuery isEqualToString:foldedQuery]
                && [self->_cachedExcludedPaths isEqualToSet:excludedSnapshot];
        NSUInteger startIndex = canContinue ? self->_cachedFilteredFileCount : 0;
        NSMutableArray<FileSearchHit *> *hits = canContinue
                ? [self->_cachedFileHits mutableCopy]
                : [NSMutableArray arrayWithCapacity:MIN(limit, (NSUInteger)64)];
#if DEBUG
        NSUInteger evaluations = 0;
#endif
        if (foldedQuery.length > 0 && limit > 0 && hits.count < limit) {
            for (NSUInteger index = startIndex; index < files.count; index++) {
                if (atomic_load(&self->_hitRequestGeneration) != generation) {
                    return;
                }
                IndexedSearchFile *file = files[index];
#if DEBUG
                evaluations++;
#endif
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
        self->_cachedFilterBuild = build;
        self->_cachedFoldedQuery = foldedQuery;
        self->_cachedExcludedPaths = excludedSnapshot;
        self->_cachedFilterLimit = limit;
        self->_cachedFilteredFileCount = files.count;
        self->_cachedFileHits = result;
#if DEBUG
        self->_lastFilterEvaluationCount = evaluations;
#endif
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
    NSArray<NSURL *> *shortestFirst = [roots sortedArrayWithOptions:NSSortStable
                                                    usingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSUInteger lengthA = VibeComparablePath(a.path).length;
        NSUInteger lengthB = VibeComparablePath(b.path).length;
        if (lengthA != lengthB) {
            return lengthA < lengthB ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    NSMutableArray<NSURL *> *kept = [NSMutableArray arrayWithCapacity:roots.count];
    NSMutableArray<NSString *> *keptPaths = [NSMutableArray arrayWithCapacity:roots.count];
    for (NSURL *root in shortestFirst) {
        NSString *path = VibeComparablePath(root.path);
        if (path.length == 0 || VibeSearchFolderCoveringRootIndex(keptPaths, path) != NSNotFound) {
            continue;
        }
        [kept addObject:root];
        [keptPaths addObject:path];
    }
    return kept;
}

- (void)setMaxIndexedFilesForTesting:(NSUInteger)cap {
    _maxIndexedFiles = cap;
}

- (NSUInteger)maxIndexedFilesForTesting {
    return _maxIndexedFiles;
}

- (NSProgress *)buildProgressForTesting {
    return _buildProgress;
}

- (void)appendFileURLForTesting:(NSURL *)url {
    NSParameterAssert(NSThread.isMainThread);
    [_files addObject:[self indexedFileForURL:url]];
}

- (NSUInteger)lastFilterEvaluationCountForTesting {
    __block NSUInteger count = 0;
#if DEBUG
    dispatch_sync(_filterQueue, ^{
        count = self->_lastFilterEvaluationCount;
    });
#endif
    return count;
}

@end
