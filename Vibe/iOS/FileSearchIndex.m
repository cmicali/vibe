//
//  FileSearchIndex.m
//  Vibe (iOS)
//

#import "FileSearchIndex.h"

#import <stdatomic.h>

#import "FileSearchIndexInternal.h"
#import "FileSearchRules.h"
#import "NSURLUtil.h"

// A cap, not a target. A provider root can be someone's whole Dropbox, and the
// index holds three strings and a URL per file — at this ceiling a few
// megabytes, walked in a few seconds. Past it the walk stops and says so.
static const NSUInteger kMaxIndexedFiles = 20000;

// How the stream is paced. Whichever comes first: enough files to be worth a
// main-thread hop and a re-filter, or long enough that the user is waiting on a
// slow directory. The interval is what makes the first results appear promptly
// on a provider tree, where a single listing can take a second by itself.
static const NSUInteger kFlushBatchSize = 128;
static const NSTimeInterval kFlushInterval = 0.2;

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

// The path, kept beside the hit so a keystroke's exclusion test is a set lookup
// on a string already in hand rather than NSURL.path per row per keystroke.
@interface VibeIndexedFile : NSObject
@property (nonatomic) FileSearchHit *hit;
@property (nonatomic) NSString *path;
@end

@implementation VibeIndexedFile
@end

static NSArray<NSString *> *VibeStandardizedPaths(NSArray<NSURL *> *urls) {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        [paths addObject:url.URLByStandardizingPath.path ?: @""];
    }
    return paths;
}

@implementation FileSearchIndex (Internal)

// TRAP: this prunes in BOTH directions, and testing only one is the bug it was
// written for. searchRoots names the open folder FIRST and the app's Documents
// directory second, and a folder picked inside Documents is the folder that has
// to go — dropping only later roots covered by earlier ones keeps them both and
// walks that tree twice, which puts every file in it on screen twice.
//
// Ancestors first, then a root is kept only when nothing already kept covers it.
+ (NSArray<NSURL *> *)pruneNestedRoots:(NSArray<NSURL *> *)roots {
    NSArray<NSURL *> *shortestFirst = [roots sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSUInteger lengthA = a.URLByStandardizingPath.path.length;
        NSUInteger lengthB = b.URLByStandardizingPath.path.length;
        if (lengthA != lengthB) {
            return lengthA < lengthB ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;   // stable, so equal-length roots keep their order
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

@end

@implementation FileSearchIndex {
    NSArray<NSURL *>           *_roots;
    NSMutableArray<VibeIndexedFile *> *_files;
    BOOL                        _built;
    // Stamped on the walk; a mismatch on a batch's arrival means the roots
    // changed under it and the batch is dropped. Read from the walk queue and
    // written from main, so atomic.
    _Atomic(uint64_t)           _buildGeneration;
    dispatch_queue_t            _walkQueue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _roots = @[];
        _files = [NSMutableArray array];
        atomic_init(&_buildGeneration, 1);
        // Utility, not user-initiated: the open the user is waiting on outranks
        // every background read (see the root CLAUDE.md), and a directory
        // listing on a file provider is the same IPC that open needs.
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _walkQueue = dispatch_queue_create("FileSearchIndex", attributes);
    }
    return self;
}

#pragma mark - Roots

- (void)setRoots:(NSArray<NSURL *> *)roots {
    NSArray<NSURL *> *pruned = [FileSearchIndex pruneNestedRoots:roots];
    if ([VibeStandardizedPaths(pruned) isEqualToArray:VibeStandardizedPaths(_roots)]) {
        return;
    }
    atomic_fetch_add(&_buildGeneration, 1);   // abandons a walk in flight
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
    NSMutableArray<VibeIndexedFile *> *batch = [NSMutableArray arrayWithCapacity:kFlushBatchSize];
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
            // One unreadable subfolder — an evicted provider directory, a
            // revoked grant — must not end the walk.
            LogWarn(@"FileSearchIndex: skipping %@ (%@)", url.lastPathComponent, error);
            return YES;
        }];
        for (NSURL *url in walk) {
            if (atomic_load(&_buildGeneration) != generation) {
                return;
            }
            // Extension first: it is pure string work, where the directory test
            // below stats the file system.
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
            VibeIndexedFile *file = [[VibeIndexedFile alloc] init];
            file.hit = [[FileSearchHit alloc] initWithURL:url];
            file.path = url.path ?: @"";
            [batch addObject:file];
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

// Walk queue only. Tolerates an empty batch, since the flush closing the walk
// is unconditional.
- (void)flushBatch:(NSArray<VibeIndexedFile *> *)batch generation:(uint64_t)generation {
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

- (NSArray<FileSearchHit *> *)hitsMatchingQuery:(NSString *)query
                                      excluding:(NSSet<NSString *> *)excludedPaths
                                          limit:(NSUInteger)limit {
    if (query.length == 0 || limit == 0) {
        return @[];
    }
    NSMutableArray<FileSearchHit *> *hits = [NSMutableArray arrayWithCapacity:MIN(limit, (NSUInteger)64)];
    for (VibeIndexedFile *file in _files) {
        if ([excludedPaths containsObject:file.path]) {
            continue;   // the playlist section is already showing it
        }
        FileSearchHit *hit = file.hit;
        if (!VibeSearchFileMatchesQuery(hit.fileName, hit.folderName, query)) {
            continue;
        }
        [hits addObject:hit];
        if (hits.count >= limit) {
            break;
        }
    }
    return hits;
}

@end
