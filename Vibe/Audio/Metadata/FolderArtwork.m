//
// FolderArtwork.m
// Vibe
//
// Locking: the lock covers _directories and nothing else. Never hold it across
// a stat, a read or a decode — the main thread takes it on every playlist cell
// draw, and a folder on a sleeping disk can block for seconds.
//
// **One entry per directory holds every fact about that directory**, so
// eviction and both invalidations are each a single pass over one dictionary.
//
// **Only background paths mutate the recency history or trim it.** The
// main-thread accessors are reads: they answer from the image caches, or from
// an entry they leave alone. scheduleResolveOfDirectory: is the exception, and
// even that is O(1) — the trim belongs to its job.
//

#import "FolderArtwork.h"
#import "AppSettings.h"
#import "FolderArtRules.h"
#import "FolderAccessManager.h"
#import "NSImage+Util.h"

#import <errno.h>
#import <fcntl.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <unistd.h>

NSNotificationName const FolderArtworkDidResolveNotification = @"FolderArtworkDidResolveNotification";

// A cover is a few hundred KB. Past this it is a scan or a print master, and
// reading it costs more than the art is worth — the folder counts as having
// none, permanently, like any other settled answer.
static const unsigned long long kMaxArtFileBytes = 20ull * 1024 * 1024;

// Decoded thumbnails, at about 64KB a folder, and display images at about 4MB.
static const NSUInteger kThumbnailCacheLimit = 64;
// Four folders' worth of display image, about 16MB: enough that a playlist
// alternating between a few albums does not re-decode a cover on every track
// change. Evicting one costs a read, never a re-probe.
static const NSUInteger kDisplayCacheLimit = 4;
// A bounded most-recently-used history: an entry is a few dozen bytes, but a
// library walk can name hundreds of thousands of folders. Over the limit,
// eviction batches down to the floor; re-probing an evicted folder costs the
// same handful of stats it did the first time.
static const NSUInteger kRecordedDirectoryLimit = 4096;
static const NSUInteger kRecordedDirectoryFloor = 3072;

// How many times a cover that is demonstrably there may fail to READ before the
// folder settles as having none anyway. A read failure is a fact about the
// moment — an unmaterialized file-provider placeholder, an interrupted read —
// so it is worth retrying; but a file that will never open must not cost every
// cell draw an open.
static const uint8_t kMaxArtReadFailures = 3;

// The settled answer for a folder: the cover's path, or this marker for "there
// is none, stop asking".
static NSString *const kNoArtMarker = @"";

// lstat rather than stat, and O_NOFOLLOW on the open below: following a link
// would read whatever it points at, which the folder's grant never covered. The
// price is that a symlinked cover.jpg is not found.
static BOOL VibeFolderArtworkFileInfo(NSString *path, unsigned long long *size) {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
            info.st_size <= 0 || (unsigned long long)info.st_size > kMaxArtFileBytes) {
        return NO;
    }
    if (size) {
        *size = (unsigned long long)info.st_size;
    }
    return YES;
}

// TRAP: O_NONBLOCK belongs on the *open* and nowhere else. It keeps a FIFO or a
// device named cover.jpg from wedging the resolver on the open itself — S_ISREG
// cannot be tested until that open returns. Left set across the reads it means
// something else entirely: a regular file whose bytes are not resident answers
// EAGAIN, which says nothing about the image.
static NSData *VibeReadFolderArtwork(NSString *path) {
    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) {
        return nil;
    }
    struct stat info;
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
            (unsigned long long)info.st_size > kMaxArtFileBytes) {
        close(descriptor);
        return nil;
    }
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) < 0) {
        // The reads would answer EAGAIN instead of blocking, indistinguishable
        // from a real failure. Give up; the caller's retry budget covers it.
        close(descriptor);
        return nil;
    }
    NSUInteger length = (NSUInteger)info.st_size;
    void *bytes = malloc(length);
    if (!bytes) {
        close(descriptor);
        return nil;
    }
    NSUInteger offset = 0;
    while (offset < length) {
        ssize_t count = read(descriptor, (char *)bytes + offset, length - offset);
        if (count > 0) {
            offset += (NSUInteger)count;
        }
        else if (count < 0 && errno == EINTR) {
            continue;
        }
        else {
            break;
        }
    }
    close(descriptor);
    if (offset != length) {
        free(bytes);
        return nil;
    }
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}

#pragma mark - One directory's state

// Everything the resolver knows about one directory. Mutated only under the
// resolver's lock, hence nonatomic throughout.
@interface VibeFolderArtEntry : NSObject

// The cover's full path, kNoArtMarker for "settled, it has none", or nil for
// "not looked at yet".
@property (nonatomic, copy, nullable) NSString *artPath;
// Unique for the resolver's lifetime, 0 for none assigned. It fences both
// discovery and decode, same-path replacement races included.
@property (nonatomic) uint64_t revision;
// The revision of the resolve claim currently held, or 0 for none.
@property (nonatomic) uint64_t resolving;
// Decodes in flight that hold no resolve claim — the settled fast path in
// displayImageForAudioFilePath:.
@property (nonatomic) NSUInteger decoding;
// A background resolve is dispatched but has not reached the queue.
@property (nonatomic) BOOL scheduled;
@property (nonatomic) uint64_t lastAccess;
// Settled as artless only because the app held no grant for the folder. These
// are the only answers a grant change may clear.
@property (nonatomic) BOOL settledWithoutGrant;
// The folder came from a bulk open, so one listing beats the lone file's stat
// probes. A fact about how the user opened it rather than a cached answer, so
// it survives an invalidate.
@property (nonatomic) BOOL preferListing;
@property (nonatomic) uint8_t readFailures;

// The folder has an answer, either way.
@property (nonatomic, readonly) BOOL settled;
// The answer is "there is no cover here".
@property (nonatomic, readonly) BOOL settledEmpty;
// Work in flight checks this entry's revision when it lands, so eviction has
// to leave it alone or it throws that work away.
@property (nonatomic, readonly) BOOL busy;

// Drops the answer, keeping the facts about how the folder was opened.
- (void)forgetSettledAnswer;

@end

@implementation VibeFolderArtEntry

- (BOOL)settled {
    return _artPath != nil;
}

- (BOOL)settledEmpty {
    return _artPath != nil && _artPath.length == 0;
}

- (BOOL)busy {
    return _resolving != 0 || _decoding > 0 || _scheduled;
}

- (void)forgetSettledAnswer {
    _artPath = nil;
    _revision = 0;
    _resolving = 0;
    _settledWithoutGrant = NO;
    _readFailures = 0;
}

@end

#pragma mark - The resolver

@implementation FolderArtwork {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, VibeFolderArtEntry *> *_directories;
    uint64_t _nextRevision;
    uint64_t _accessClock;
    NSCache<NSString *, VibeImage *> *_thumbnails;
    NSCache<NSString *, VibeImage *> *_displayImages;
    dispatch_queue_t _queue;
    // The album-art setting, cached: directoryForAudioFilePath: gates every
    // accessor on it, and those run on every cell draw and every updateUI pass
    // — far too hot for a defaults read apiece. -1 is unknown; only an
    // invalidate clears it. Two racers both asking the provider is harmless.
    atomic_int _enabledCache;
    FolderArtworkEnabledProvider _enabledProvider;
    FolderArtworkAccessProvider _accessProvider;
    FolderArtworkDirectoryLister _lister;
    FolderArtworkFileInfoProvider _fileInfo;
    FolderArtworkDataReader _dataReader;
    FolderArtworkDecoder _decoder;
}

+ (instancetype)sharedInstance {
    static FolderArtwork *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[FolderArtwork alloc] init];
    });
    return instance;
}

- (instancetype)init {
    return [self initWithEnabledProvider:^BOOL{
        return Settings.useFolderArtwork;
    } accessProvider:^BOOL(NSString *directory) {
        return [FolderAccessManager.sharedInstance canReadInsideDirectory:directory];
    }];
}

- (instancetype)initWithEnabledProvider:(FolderArtworkEnabledProvider)enabledProvider
                         accessProvider:(FolderArtworkAccessProvider)accessProvider {
    return [self initWithEnabledProvider:enabledProvider
                          accessProvider:accessProvider
                                  lister:^NSArray<NSString *> *(NSString *directory) {
        return [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return VibeFolderArtworkFileInfo(path, size);
    } dataReader:^NSData *(NSString *path) {
        return VibeReadFolderArtwork(path);
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return [NSImage decodedImageWithData:data maxPixelSize:maxPixelSize];
    }];
}

- (instancetype)initWithEnabledProvider:(FolderArtworkEnabledProvider)enabledProvider
                         accessProvider:(FolderArtworkAccessProvider)accessProvider
                                 lister:(FolderArtworkDirectoryLister)lister
                               fileInfo:(FolderArtworkFileInfoProvider)fileInfo
                             dataReader:(FolderArtworkDataReader)dataReader
                                decoder:(FolderArtworkDecoder)decoder {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _directories = [NSMutableDictionary dictionary];
        _thumbnails = [[NSCache alloc] init];
        _thumbnails.countLimit = kThumbnailCacheLimit;
        _displayImages = [[NSCache alloc] init];
        _displayImages.countLimit = kDisplayCacheLimit;
        atomic_init(&_enabledCache, -1);
        // Serial and background: never urgent, and one folder at a time keeps a
        // big playlist's scrolling from turning into a disk storm.
        _queue = dispatch_queue_create("com.vibe.folderartwork",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _enabledProvider = [enabledProvider copy];
        _accessProvider = [accessProvider copy];
        _lister = [lister copy];
        _fileInfo = [fileInfo copy];
        _dataReader = [dataReader copy];
        _decoder = [decoder copy];
    }
    return self;
}

#pragma mark - Accessors

- (VibeImage *)cachedThumbnailForAudioFilePath:(NSString *)path
                              resolveIfUnknown:(BOOL)resolveIfUnknown {
    NSString *directory = [self directoryForAudioFilePath:path];
    if (!directory) {
        return nil;
    }
    NSImage *thumbnail = [_thumbnails objectForKey:directory];
    if (thumbnail) {
        return thumbnail;
    }
    if (resolveIfUnknown) {
        [self scheduleResolveOfDirectory:directory];
    }
    return nil;
}

- (VibeImage *)cachedDisplayImageForAudioFilePath:(NSString *)path {
    NSString *directory = [self directoryForAudioFilePath:path];
    return directory ? [_displayImages objectForKey:directory] : nil;
}

- (VibeImage *)displayImageForAudioFilePath:(NSString *)path {
    NSString *directory = [self directoryForAudioFilePath:path];
    if (!directory) {
        return nil;
    }
    NSImage *cached = [_displayImages objectForKey:directory];
    if (cached) {
        return cached;
    }
    // A settled cover decodes without the resolve claim: decoding does no
    // directory I/O, so a background resolve of the same folder is no reason to
    // send the current track's header away empty. Pin it for the decode
    // instead, which is all eviction needs to leave it alone.
    os_unfair_lock_lock(&_lock);
    VibeFolderArtEntry *entry = _directories[directory];
    NSString *settled = entry.artPath;
    uint64_t settledRevision = entry.revision;
    BOOL decodeSettled = settled.length > 0 && settledRevision != 0;
    if (entry) {
        [self touchLocked:entry];
    }
    if (decodeSettled) {
        entry.decoding += 1;
    }
    os_unfair_lock_unlock(&_lock);
    if (settled != nil) {
        if (!decodeSettled) {
            return nil; // settled: this folder has none
        }
        NSImage *display = [self loadDisplayArtAtPath:settled directory:directory
                                             revision:settledRevision];
        os_unfair_lock_lock(&_lock);
        // The same entry object unless an invalidate dropped it, which the
        // guard covers: an entry it recreated was never pinned by this decode.
        VibeFolderArtEntry *pinned = _directories[directory];
        if (pinned.decoding > 0) {
            pinned.decoding -= 1;
        }
        os_unfair_lock_unlock(&_lock);
        return display;
    }
    uint64_t revision = [self claimDirectory:directory];
    if (revision == 0) {
        return nil;
    }
    NSString *artPath = [self resolveDirectory:directory revision:revision didSettle:NULL];
    NSImage *display = artPath ? [self loadDisplayArtAtPath:artPath directory:directory
                                                   revision:revision] : nil;
    [self releaseDirectory:directory revision:revision];
    return display;
}

- (BOOL)needsBackgroundLoadForAudioFilePath:(NSString *)path {
    NSString *directory = [self directoryForAudioFilePath:path];
    if (!directory) {
        return NO;
    }
    if ([_displayImages objectForKey:directory]) {
        return NO;
    }
    // Read-only: this runs on the main thread's updateUI pass, and the resolve
    // it answers for touches the entry itself the moment it starts.
    os_unfair_lock_lock(&_lock);
    BOOL needed = !_directories[directory].settledEmpty;
    os_unfair_lock_unlock(&_lock);
    return needed;
}

- (NSString *)settledArtPathForDirectory:(NSString *)directory {
    if (directory.length == 0) {
        return nil;
    }
    os_unfair_lock_lock(&_lock);
    NSString *artPath = _directories[directory].artPath;
    os_unfair_lock_unlock(&_lock);
    return artPath;
}

- (NSUInteger)recordedDirectoryCount {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = _directories.count;
    os_unfair_lock_unlock(&_lock);
    return count;
}

#pragma mark - What the caller already knows

- (void)noteListedDirectories:(NSSet<NSString *> *)directories
       artFilenameByDirectory:(NSDictionary<NSString *, NSString *> *)artFilenameByDirectory {
    if (directories.count == 0) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    for (NSString *directory in directories) {
        if (directory.length == 0) {
            continue;
        }
        NSString *artFilename = artFilenameByDirectory[directory];
        BOOL validFilename = artFilename.length > 0 &&
                [artFilename isEqualToString:artFilename.lastPathComponent] &&
                VibeFolderArtCandidateRank(artFilename) != NSNotFound;
        NSString *artPath = validFilename
                ? [directory stringByAppendingPathComponent:artFilename] : kNoArtMarker;
        VibeFolderArtEntry *entry = [self entryLocked:directory create:YES];
        entry.preferListing = NO;
        // Re-listing the same answer keeps the revision, so cached images and
        // in-flight decodes of that same cover stay valid.
        if (entry.revision != 0 && [entry.artPath isEqualToString:artPath]) {
            continue;
        }
        entry.revision = [self newRevisionLocked];
        entry.artPath = artPath;
        entry.resolving = 0;
        entry.readFailures = 0;
        // A listing saw the whole folder, so this answer stands on its own
        // merits rather than on a missing grant.
        entry.settledWithoutGrant = NO;
        [_thumbnails removeObjectForKey:directory];
        [_displayImages removeObjectForKey:directory];
    }
    [self trimLocked];
    os_unfair_lock_unlock(&_lock);
}

- (void)preferListingForDirectories:(NSSet<NSString *> *)directories {
    if (directories.count == 0) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    for (NSString *directory in directories) {
        if (directory.length == 0 || _directories[directory].settled) {
            continue; // a settled folder is not revisited, listing or not
        }
        [self entryLocked:directory create:YES].preferListing = YES;
    }
    [self trimLocked];
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Invalidation

- (void)albumArtSettingDidChange {
    // The only place the cached setting is dropped. The settled answers stay;
    // see the header for why this exists separately from invalidate.
    atomic_store_explicit(&_enabledCache, -1, memory_order_relaxed);
    [_thumbnails removeAllObjects];
    [_displayImages removeAllObjects];
}

- (void)invalidate {
    atomic_store_explicit(&_enabledCache, -1, memory_order_relaxed);
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *forgotten = [NSMutableArray array];
    for (NSString *directory in _directories) {
        VibeFolderArtEntry *entry = _directories[directory];
        [entry forgetSettledAnswer];
        entry.preferListing = NO;
        // Busy entries stay: work in flight decrements a pin on them, and
        // fences on a revision forgetSettledAnswer has already moved out from
        // under it.
        if (!entry.busy) {
            [forgotten addObject:directory];
        }
    }
    [_directories removeObjectsForKeys:forgotten];
    [_thumbnails removeAllObjects];
    [_displayImages removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

- (void)invalidateDirectoriesSettledWithoutGrant {
    os_unfair_lock_lock(&_lock);
    for (NSString *directory in _directories) {
        VibeFolderArtEntry *entry = _directories[directory];
        if (entry.settledWithoutGrant) {
            // No image can exist for these: nothing was ever read for them.
            [entry forgetSettledAnswer];
        }
    }
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Entries

- (BOOL)folderArtworkEnabled {
    int cached = atomic_load_explicit(&_enabledCache, memory_order_relaxed);
    if (cached >= 0) {
        return cached != 0;
    }
    BOOL enabled = _enabledProvider();
    atomic_store_explicit(&_enabledCache, enabled ? 1 : 0, memory_order_relaxed);
    return enabled;
}

- (NSString *)directoryForAudioFilePath:(NSString *)path {
    if (path.length == 0 || ![self folderArtworkEnabled]) {
        return nil;
    }
    NSString *directory = path.stringByDeletingLastPathComponent;
    return directory.length > 0 ? directory : nil;
}

- (VibeFolderArtEntry *)entryLocked:(NSString *)directory create:(BOOL)create {
    VibeFolderArtEntry *entry = _directories[directory];
    if (!entry && create) {
        entry = [VibeFolderArtEntry new];
        _directories[directory] = entry;
    }
    if (entry) {
        [self touchLocked:entry];
    }
    return entry;
}

// The entry for this directory if it is still the one the caller's work belongs
// to: same revision, and — when the caller names one — the same cover path. nil
// means an invalidate or a re-listing overtook the work, so drop what it
// produced rather than storing it.
- (VibeFolderArtEntry *)currentEntryLocked:(NSString *)directory
                                  revision:(uint64_t)revision
                                   artPath:(NSString *)artPath {
    VibeFolderArtEntry *entry = _directories[directory];
    if (revision == 0 || !entry || entry.revision != revision) {
        return nil;
    }
    if (artPath && ![entry.artPath isEqualToString:artPath]) {
        return nil;
    }
    return entry;
}

- (uint64_t)newRevisionLocked {
    return ++_nextRevision;
}

- (void)touchLocked:(VibeFolderArtEntry *)entry {
    entry.lastAccess = ++_accessClock;
}

// Evicts in one batch down to the floor rather than one entry per call: this
// runs under the lock, and trimming one entry per new directory would sort the
// whole history thousands of times over a large library. Batching pays for the
// sort about once per (limit - floor) new folders, and sorting raw access
// clocks costs no NSNumber comparisons and no dictionary copy.
- (void)trimLocked {
    if (_directories.count <= kRecordedDirectoryLimit) {
        return;
    }
    NSMutableArray<NSString *> *evictable = [NSMutableArray arrayWithCapacity:_directories.count];
    for (NSString *directory in _directories) {
        if (!_directories[directory].busy) {
            [evictable addObject:directory];
        }
    }
    NSUInteger wanted = _directories.count - kRecordedDirectoryFloor;
    NSUInteger count = MIN(wanted, evictable.count);
    if (count == 0) {
        return;
    }
    uint64_t *clocks = malloc(evictable.count * sizeof(uint64_t));
    if (!clocks) {
        return;
    }
    for (NSUInteger index = 0; index < evictable.count; index++) {
        clocks[index] = _directories[evictable[index]].lastAccess;
    }
    qsort_b(clocks, evictable.count, sizeof(uint64_t), ^int(const void *left, const void *right) {
        uint64_t a = *(const uint64_t *)left, b = *(const uint64_t *)right;
        return a < b ? -1 : (a > b ? 1 : 0);
    });
    // Clocks are unique, so everything at or below the cutoff is exactly the
    // count oldest entries.
    uint64_t cutoff = clocks[count - 1];
    free(clocks);
    for (NSString *directory in evictable) {
        if (_directories[directory].lastAccess <= cutoff) {
            [_directories removeObjectForKey:directory];
        }
    }
}

#pragma mark - Claims and settling

- (uint64_t)claimDirectory:(NSString *)directory {
    os_unfair_lock_lock(&_lock);
    VibeFolderArtEntry *entry = [self entryLocked:directory create:YES];
    uint64_t revision = 0;
    if (entry.resolving == 0) {
        revision = entry.revision != 0 ? entry.revision : [self newRevisionLocked];
        entry.revision = revision;
        entry.resolving = revision;
    }
    [self trimLocked];
    os_unfair_lock_unlock(&_lock);
    return revision;
}

- (void)releaseDirectory:(NSString *)directory revision:(uint64_t)revision {
    os_unfair_lock_lock(&_lock);
    VibeFolderArtEntry *entry = _directories[directory];
    if (entry.resolving == revision) {
        entry.resolving = 0;
    }
    [self trimLocked];
    os_unfair_lock_unlock(&_lock);
}

// artPath nil settles the folder as having no cover.
- (void)settleEntryLocked:(VibeFolderArtEntry *)entry artPath:(NSString *)artPath {
    entry.artPath = artPath ?: kNoArtMarker;
    entry.readFailures = 0;
    [self touchLocked:entry];
}

- (BOOL)settleDirectory:(NSString *)directory artPath:(NSString *)artPath
               revision:(uint64_t)revision withoutGrant:(BOOL)withoutGrant {
    os_unfair_lock_lock(&_lock);
    VibeFolderArtEntry *entry = [self currentEntryLocked:directory revision:revision artPath:nil];
    if (entry) {
        [self settleEntryLocked:entry artPath:artPath];
        entry.settledWithoutGrant = withoutGrant;
        [self trimLocked];
    }
    os_unfair_lock_unlock(&_lock);
    return entry != nil;
}

- (BOOL)storeImage:(NSImage *)image
           inCache:(NSCache<NSString *, NSImage *> *)cache
         directory:(NSString *)directory
           artPath:(NSString *)artPath
          revision:(uint64_t)revision {
    os_unfair_lock_lock(&_lock);
    VibeFolderArtEntry *entry = [self currentEntryLocked:directory revision:revision artPath:artPath];
    if (entry) {
        [cache setObject:image forKey:directory];
        [self touchLocked:entry];
    }
    os_unfair_lock_unlock(&_lock);
    return entry != nil;
}

- (BOOL)isRevisionCurrent:(uint64_t)revision
             forDirectory:(NSString *)directory
                  artPath:(NSString *)artPath {
    os_unfair_lock_lock(&_lock);
    BOOL current = [self currentEntryLocked:directory revision:revision artPath:artPath] != nil;
    os_unfair_lock_unlock(&_lock);
    return current;
}

#pragma mark - Resolving

// A cell draw asks on every pass, and a playlist of a thousand tracks in one
// folder must produce one job. Worth running whenever the thumbnail is missing
// — unresolved folder, resolved by the header's display-size path, or an
// evicted thumbnail — and worth skipping only for a folder settled as having no
// cover, or one whose job is already out.
//
// One critical section, and deliberately O(1): this is a cell draw, on the main
// thread. Claiming the revision and trimming the history are the job's own
// first acts, on the resolver queue, where they cost nobody a frame.
- (void)scheduleResolveOfDirectory:(NSString *)directory {
    os_unfair_lock_lock(&_lock);
    VibeFolderArtEntry *entry = _directories[directory];
    BOOL skip = entry != nil && (entry.settledEmpty || entry.resolving != 0 || entry.scheduled);
    if (!skip) {
        [self entryLocked:directory create:YES].scheduled = YES;
    }
    os_unfair_lock_unlock(&_lock);
    if (skip) {
        return;
    }
    __weak FolderArtwork *weakSelf = self;
    dispatch_async(_queue, ^{
        [weakSelf resolveScheduledDirectory:directory];
    });
}

- (void)resolveScheduledDirectory:(NSString *)directory {
    // Claim first, clear the mark second, so the two overlap: a cell draw
    // landing in between sees the mark, and one landing after sees the claim.
    // Clearing first leaves a gap in which a draw schedules a redundant job.
    uint64_t revision = [self claimDirectory:directory];
    os_unfair_lock_lock(&_lock);
    _directories[directory].scheduled = NO;
    os_unfair_lock_unlock(&_lock);
    if (revision == 0) {
        return;
    }
    BOOL settled = NO;
    NSString *artPath = [self resolveDirectory:directory revision:revision didSettle:&settled];
    BOOL stored = NO;
    if (artPath) {
        NSImage *thumbnail = [self loadThumbnailArtAtPath:artPath directory:directory
                                                 revision:revision];
        stored = thumbnail != nil && [self storeImage:thumbnail inCache:_thumbnails
                                            directory:directory artPath:artPath revision:revision];
    }
    [self releaseDirectory:directory revision:revision];
    // Settling is news even when the news is "there is no cover here": the
    // header holds the *previous* track's art while the answer is pending, so
    // without a post for the empty answer a track whose own folder-art load
    // lost this claim race keeps that stale cover on screen.
    if (!settled && !stored) {
        return;
    }
    __weak FolderArtwork *weakSelf = self;
    run_on_main_thread({
        FolderArtwork *strongSelf = weakSelf;
        if (![strongSelf isRevisionCurrent:revision forDirectory:directory
                                   artPath:stored ? artPath : nil]) {
            return;
        }
        [NSNotificationCenter.defaultCenter postNotificationName:FolderArtworkDidResolveNotification
                                                          object:strongSelf];
    });
}

// Finds the folder's cover and settles the answer either way. Blocking: a
// handful of stats, or one listing for a bulk-opened folder. Returns the
// cover's path, or nil for a folder with none — and nil too when an invalidate
// overtook the answer, which the next ask resolves afresh. didSettle tells
// those two apart.
- (NSString *)resolveDirectory:(NSString *)directory revision:(uint64_t)revision
                     didSettle:(BOOL *)didSettle {
    if (didSettle) {
        *didSettle = NO;
    }
    os_unfair_lock_lock(&_lock);
    VibeFolderArtEntry *entry = [self currentEntryLocked:directory revision:revision artPath:nil];
    NSString *settled = entry.artPath;
    BOOL byListing = entry.preferListing;
    if (entry) {
        [self touchLocked:entry];
    }
    os_unfair_lock_unlock(&_lock);
    if (!entry || settled != nil) {
        return settled.length > 0 ? settled : nil;
    }
    // Nobody asked for this artwork, so it must not raise a permission panel:
    // leave an ungranted folder untouched rather than probing it, since the
    // protected folders answer an unsanctioned read with a system consent
    // dialog. A grant arriving later clears this answer through
    // MainPlayerController.grantedFoldersDidChange:.
    if (!_accessProvider(directory)) {
        LogDebug(@"No folder grant for %@ — skipping folder art", directory);
        if ([self settleDirectory:directory artPath:nil revision:revision withoutGrant:YES] &&
                didSettle) {
            *didSettle = YES;
        }
        return nil;
    }
    NSString *artPath = byListing ? [self artPathByListing:directory]
                                  : [self artPathByProbing:directory];
    if (![self settleDirectory:directory artPath:artPath revision:revision withoutGrant:NO]) {
        return nil;
    }
    if (didSettle) {
        *didSettle = YES;
    }
    return artPath;
}

// The lone-file strategy: one stat per candidate, best first, stopping at the
// first hit — the usual folder costs a single syscall, the worst case
// kVibeFolderArtStatProbeCount. Only the commonest spellings are worth asking
// about blind; the rest are found by listing, where they are free.
- (NSString *)artPathByProbing:(NSString *)directory {
    NSArray<NSString *> *candidates = VibeFolderArtCandidateFilenames();
    NSUInteger probes = MIN(kVibeFolderArtStatProbeCount, candidates.count);
    for (NSUInteger i = 0; i < probes; i++) {
        NSString *path = [directory stringByAppendingPathComponent:candidates[i]];
        // stat rather than NSFileManager: one syscall, no attribute dictionary
        // per probe, and it answers the size question along with existence.
        if (_fileInfo(path, NULL)) {
            return path;
        }
    }
    return nil;
}

// The bulk-open strategy: the folders came from an open already walking the
// disk, so one listing buys every spelling and capitalization at once. A folder
// drop normally never reaches here — its walk settled the answer through
// noteListedDirectories:artFilenameByDirectory: — but a folder whose grant
// arrived late lands here when that grant invalidates its answer.
- (NSString *)artPathByListing:(NSString *)directory {
    NSArray<NSString *> *filenames = _lister(directory);
    NSString *filename = VibeFolderArtBestCandidate(filenames);
    if (!filename) {
        return nil;
    }
    NSString *path = [directory stringByAppendingPathComponent:filename];
    return _fileInfo(path, NULL) ? path : nil;
}

#pragma mark - Loading a cover

// The one place a cover file is ever opened, so the log line answers "did
// anything actually load?".
//
// **A read failure and a decode failure are not the same failure**, which is
// why the read is a step of its own. Bytes that will not decode are a fact
// about the image and settle the folder for good; see decodeArtData:. Bytes
// that could not be READ are a fact about the moment — an unmaterialized
// placeholder, an interrupted read, a volume that went away — so the cover is
// kept and the next ask retries, up to kMaxArtReadFailures.
- (NSData *)readArtAtPath:(NSString *)artPath
                directory:(NSString *)directory
                 revision:(uint64_t)revision {
    LogDebug(@"Loading folder art %@", artPath);
    NSData *data = _dataReader(artPath);
    os_unfair_lock_lock(&_lock);
    VibeFolderArtEntry *entry = [self currentEntryLocked:directory revision:revision artPath:artPath];
    if (data) {
        entry.readFailures = 0;
    }
    else if (entry) {
        entry.readFailures = (uint8_t)(entry.readFailures + 1);
        if (entry.readFailures >= kMaxArtReadFailures) {
            LogWarn(@"Folder art at %@ failed to read %u times — the folder counts as having none",
                    artPath, kMaxArtReadFailures);
            [self settleEntryLocked:entry artPath:nil];
            [_thumbnails removeObjectForKey:directory];
            [_displayImages removeObjectForKey:directory];
        }
        else {
            LogWarn(@"Folder art at %@ could not be read; keeping it for another try", artPath);
        }
    }
    os_unfair_lock_unlock(&_lock);
    return data;
}

// Unlike a read failure this is permanent for these bytes, so the folder counts
// as having no cover rather than costing every track in it a fresh decode.
- (NSImage *)decodeArtData:(NSData *)data
                    atPath:(NSString *)artPath
                 directory:(NSString *)directory
                  revision:(uint64_t)revision
              maxPixelSize:(CGFloat)maxPixelSize {
    NSImage *image = _decoder(data, maxPixelSize);
    if (image) {
        return image;
    }
    LogWarn(@"Folder art at %@ could not be decoded", artPath);
    os_unfair_lock_lock(&_lock);
    VibeFolderArtEntry *entry = [self currentEntryLocked:directory revision:revision artPath:artPath];
    if (entry) {
        [self settleEntryLocked:entry artPath:nil];
        [_thumbnails removeObjectForKey:directory];
        [_displayImages removeObjectForKey:directory];
    }
    os_unfair_lock_unlock(&_lock);
    return nil;
}

- (NSImage *)loadThumbnailArtAtPath:(NSString *)artPath
                          directory:(NSString *)directory
                           revision:(uint64_t)revision {
    NSData *data = [self readArtAtPath:artPath directory:directory revision:revision];
    return data ? [self decodeArtData:data atPath:artPath directory:directory
                             revision:revision maxPixelSize:kVibeThumbnailArtDimension] : nil;
}

// The header's size, plus the row thumbnail off the same bytes: read once,
// decode twice, rather than reading again the moment a row for the same folder
// draws. Only this direction is free — 128px cannot be enlarged back to 1024 —
// so a folder whose rows draw before its header still pays two reads.
- (NSImage *)loadDisplayArtAtPath:(NSString *)artPath
                        directory:(NSString *)directory
                         revision:(uint64_t)revision {
    NSData *data = [self readArtAtPath:artPath directory:directory revision:revision];
    if (!data) {
        return nil;
    }
    NSImage *display = [self decodeArtData:data atPath:artPath directory:directory
                                  revision:revision maxPixelSize:kVibeDisplayArtDimension];
    if (!display) {
        return nil;
    }
    if (![_thumbnails objectForKey:directory]) {
        // Straight to the decoder: the display decode just proved these bytes
        // are an image, so a failure here is about the size alone and must not
        // settle the folder.
        NSImage *thumbnail = _decoder(data, kVibeThumbnailArtDimension);
        if (thumbnail) {
            [self storeImage:thumbnail inCache:_thumbnails
                   directory:directory artPath:artPath revision:revision];
        }
    }
    return [self storeImage:display inCache:_displayImages
                  directory:directory artPath:artPath revision:revision] ? display : nil;
}

@end
