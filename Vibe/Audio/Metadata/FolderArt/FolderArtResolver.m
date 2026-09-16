//
// FolderArtResolver.m
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

#import "FolderArtResolverInternal.h"
#import "FolderArtEntry.h"
#import "FolderArtFileIO.h"
#import "AppSettings.h"
#if TARGET_OS_OSX
#import "AppSettings+Mac.h"
#endif
#import "FolderArtRules.h"
#if TARGET_OS_OSX
#import "FolderAccessManager.h"    // the macOS grant list; see -init
#endif
#import "PlatformImage.h"

#import <os/lock.h>
#import <stdatomic.h>

NSNotificationName const FolderArtDidResolveNotification = @"FolderArtDidResolveNotification";

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

#pragma mark - The resolver

@implementation FolderArtResolver {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, FolderArtEntry *> *_directories;
    uint64_t _nextAnswerGeneration;
    uint64_t _accessClock;
    // Fences a denied read against a concurrent grant-restoration notification:
    // a denial that predates the change must not park the path after that change
    // already re-armed it. Guarded by _lock.
    uint64_t _accessGeneration;
    NSCache<NSString *, VibeImage *> *_thumbnails;
    NSCache<NSString *, VibeImage *> *_displayImages;
    dispatch_queue_t _queue;
    // The album-art setting, cached: directoryForAudioFilePath: gates every
    // accessor on it, and those run on every cell draw and every updateUI pass
    // — far too hot for a defaults read apiece. -1 is unknown; only an
    // invalidate clears it. Two racers both asking the provider is harmless.
    atomic_int _enabledCache;
    FolderArtEnabledProvider _enabledProvider;
    FolderArtAccessProvider _accessProvider;
    FolderArtDirectoryLister _lister;
    FolderArtFileInfoProvider _fileInfo;
    FolderArtDataReader _dataReader;
    FolderArtDecoder _decoder;
}

+ (instancetype)sharedInstance {
    static FolderArtResolver *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[FolderArtResolver alloc] init];
    });
    return instance;
}

- (instancetype)init {
    return [self initWithEnabledProvider:^BOOL{
#if TARGET_OS_OSX
        return AppSettings.sharedInstance.useFolderArt;
#else
        // Folder art is a macOS feature: AudioTrackArtwork leaves its resolver
        // handle nil on iOS, so nothing here is reachable — and if that ever
        // changes, it stays off rather than silently switching on.
        return NO;
#endif
    } accessProvider:^BOOL(NSString *directory) {
#if TARGET_OS_OSX
        return [FolderAccessManager.sharedInstance canReadInsideDirectory:directory];
#else
        // iOS has no unsanctioned-read consent panel to avoid, and no
        // app-scoped grant list: FolderSession holds the security scope of the
        // one picked folder for the session, and everything the app can name
        // is inside it. So the probe that macOS must earn is free here.
        return YES;
#endif
    }];
}

- (instancetype)initWithEnabledProvider:(FolderArtEnabledProvider)enabledProvider
                         accessProvider:(FolderArtAccessProvider)accessProvider {
    return [self initWithEnabledProvider:enabledProvider
                          accessProvider:accessProvider
                                  lister:^NSArray<NSString *> *(NSString *directory) {
        return [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return VibeFolderArtFileInfo(path, size);
    } dataReader:^NSData *(NSString *path) {
        return VibeReadFolderArt(path);
    } decoder:^VibeImage *(NSData *data, CGFloat maxPixelSize) {
        return VibeDecodedImageWithData(data, maxPixelSize);
    }];
}

- (instancetype)initWithEnabledProvider:(FolderArtEnabledProvider)enabledProvider
                         accessProvider:(FolderArtAccessProvider)accessProvider
                                 lister:(FolderArtDirectoryLister)lister
                               fileInfo:(FolderArtFileInfoProvider)fileInfo
                             dataReader:(FolderArtDataReader)dataReader
                                decoder:(FolderArtDecoder)decoder {
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
        _queue = dispatch_queue_create("com.vibe.folderart",
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
    VibeImage *thumbnail = [_thumbnails objectForKey:directory];
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
    VibeImage *cached = [_displayImages objectForKey:directory];
    if (cached) {
        return cached;
    }
    // A settled cover decodes without the resolve claim: decoding does no
    // directory I/O, so a background resolve of the same folder is no reason to
    // send the current track's header away empty. Pin it for the decode
    // instead, which is all eviction needs to leave it alone.
    os_unfair_lock_lock(&_lock);
    FolderArtEntry *entry = _directories[directory];
    NSString *settled = entry.artPath;
    uint64_t settledAnswerGeneration = entry.answerGeneration;
    BOOL decodeSettled = settled.length > 0 && settledAnswerGeneration != 0 &&
            !entry.readBlockedWithoutGrant;
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
        // Read before the decode, because the decode is what fills it.
        BOOL thumbnailWasMissing = [_thumbnails objectForKey:directory] == nil;
        VibeImage *display = [self loadDisplayArtAtPath:settled directory:directory
                                             answerGeneration:settledAnswerGeneration];
        os_unfair_lock_lock(&_lock);
        // The same entry object unless an invalidate dropped it, which the
        // guard covers: an entry it recreated was never pinned by this decode.
        FolderArtEntry *pinned = _directories[directory];
        if (pinned.decoding > 0) {
            pinned.decoding -= 1;
        }
        os_unfair_lock_unlock(&_lock);
        // The display decode also fills the row-thumbnail cache from the same
        // bytes, so the first one for a directory is a real redraw edge for
        // rows that had nothing. Later decodes of the same settled cover are
        // not: the thumbnail is already cached, and posting again would cost a
        // reloadVisibleTracks plus an updateUI on every track change through
        // this folder once the four-entry display cache has evicted it. A
        // failed decode is never an edge — nothing new became drawable.
        if (display && thumbnailWasMissing) {
            [self postResolutionNotificationForDirectory:directory
                                                 answerGeneration:settledAnswerGeneration
                                                  artPath:settled];
        }
        return display;
    }
    uint64_t answerGeneration = [self claimDirectory:directory];
    if (answerGeneration == 0) {
        return nil;
    }
    BOOL settledAnswer = NO;
    NSString *artPath = [self resolveDirectory:directory answerGeneration:answerGeneration
                                      didSettle:&settledAnswer];
    VibeImage *display = artPath ? [self loadDisplayArtAtPath:artPath directory:directory
                                                   answerGeneration:answerGeneration] : nil;
    [self releaseDirectory:directory answerGeneration:answerGeneration];
    // A row that asked while this claim was held skipped its own resolver job,
    // so the blocking owner supplies its redraw edge. Two answers are one:
    // pixels this decode produced, and a settled "this folder has none", which
    // still has to arrive because the header deliberately holds the previous
    // track's art until the answer does. A settled cover this decode could NOT
    // read is neither — nothing became drawable and the answer has not moved —
    // so it gets no edge, and the retry (readArtAtPath: keeps the answer and
    // counts the failure) supplies one if it succeeds.
    //
    // The artPath is the post's fence against a cover replaced while the decode
    // ran, so it must name what this decode actually drew. nil is "whatever the
    // entry holds now", correct only for the no-cover case, which has no path.
    BOOL settledWithNoCover = settledAnswer && artPath == nil;
    if (display || settledWithNoCover) {
        [self postResolutionNotificationForDirectory:directory
                                             answerGeneration:answerGeneration
                                              artPath:display ? artPath : nil];
    }
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
    FolderArtEntry *entry = _directories[directory];
    BOOL needed = !entry.settledEmpty && !entry.readBlockedWithoutGrant;
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
        FolderArtEntry *entry = [self entryLocked:directory create:YES];
        entry.preferListing = NO;
        // Re-listing the same answer keeps its generation, so cached images
        // and in-flight decodes of that same cover stay valid.
        if (entry.answerGeneration != 0 && [entry.artPath isEqualToString:artPath]) {
            continue;
        }
        entry.answerGeneration = [self newAnswerGenerationLocked];
        entry.artPath = artPath;
        entry.resolving = 0;
        entry.readFailures = 0;
        entry.readBlockedWithoutGrant = NO;
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

- (void)folderArtSettingDidChange {
    // TRAP: the only place the cached useFolderArt is dropped, so a writer
    // that skips VibeSettingsLiveEffectFolderArt is not observed. Not a full
    // wipe: the settled answers stay; see the header for why this exists
    // separately from invalidate.
    atomic_store_explicit(&_enabledCache, -1, memory_order_relaxed);
    [_thumbnails removeAllObjects];
    [_displayImages removeAllObjects];
}

- (void)invalidate {
    atomic_store_explicit(&_enabledCache, -1, memory_order_relaxed);
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *forgotten = [NSMutableArray array];
    for (NSString *directory in _directories) {
        FolderArtEntry *entry = _directories[directory];
        [entry forgetSettledAnswer];
        entry.preferListing = NO;
        // Busy entries stay: work in flight decrements a pin on them, and
        // fences on a generation forgetSettledAnswer has already moved out
        // from under it.
        if (!entry.busy) {
            [forgotten addObject:directory];
        }
    }
    [_directories removeObjectsForKeys:forgotten];
    [_thumbnails removeAllObjects];
    [_displayImages removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

// TRAP: not a full wipe either — only unresolved no-grant answers are
// forgotten, and every discovered cover path survives. invalidate is the wipe,
// and it is test and diagnostic surface only.
- (void)invalidateDirectoriesSettledWithoutGrant {
    os_unfair_lock_lock(&_lock);
    _accessGeneration++;
    for (NSString *directory in _directories) {
        FolderArtEntry *entry = _directories[directory];
        if (entry.settledWithoutGrant) {
            // No image can exist for these: nothing was ever read for them.
            [entry forgetSettledAnswer];
        }
        // A known cover whose read was blocked keeps its donated path. Any grant
        // change may have restored the scope; the next request rechecks access at
        // the read boundary before touching the file.
        entry.readBlockedWithoutGrant = NO;
    }
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Entries

- (BOOL)folderArtEnabled {
    int cached = atomic_load_explicit(&_enabledCache, memory_order_relaxed);
    if (cached >= 0) {
        return cached != 0;
    }
    BOOL enabled = _enabledProvider();
    atomic_store_explicit(&_enabledCache, enabled ? 1 : 0, memory_order_relaxed);
    return enabled;
}

- (NSString *)directoryForAudioFilePath:(NSString *)path {
    if (path.length == 0 || ![self folderArtEnabled]) {
        return nil;
    }
    NSString *directory = path.stringByDeletingLastPathComponent;
    return directory.length > 0 ? directory : nil;
}

- (FolderArtEntry *)entryLocked:(NSString *)directory create:(BOOL)create {
    FolderArtEntry *entry = _directories[directory];
    if (!entry && create) {
        entry = [FolderArtEntry new];
        _directories[directory] = entry;
    }
    if (entry) {
        [self touchLocked:entry];
    }
    return entry;
}

// The entry for this directory if it is still the one the caller's work belongs
// to: same generation, and — when the caller names one — the same cover path.
// nil means an invalidate or a re-listing overtook the work, so drop what it
// produced rather than storing it.
- (FolderArtEntry *)currentEntryLocked:(NSString *)directory
                                  answerGeneration:(uint64_t)answerGeneration
                                   artPath:(NSString *)artPath {
    FolderArtEntry *entry = _directories[directory];
    if (answerGeneration == 0 || !entry || entry.answerGeneration != answerGeneration) {
        return nil;
    }
    if (artPath && ![entry.artPath isEqualToString:artPath]) {
        return nil;
    }
    return entry;
}

- (uint64_t)newAnswerGenerationLocked {
    return ++_nextAnswerGeneration;
}

- (void)touchLocked:(FolderArtEntry *)entry {
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
    FolderArtEntry *entry = [self entryLocked:directory create:YES];
    uint64_t answerGeneration = 0;
    if (entry.resolving == 0) {
        answerGeneration = entry.answerGeneration != 0 ? entry.answerGeneration : [self newAnswerGenerationLocked];
        entry.answerGeneration = answerGeneration;
        entry.resolving = answerGeneration;
    }
    [self trimLocked];
    os_unfair_lock_unlock(&_lock);
    return answerGeneration;
}

- (void)releaseDirectory:(NSString *)directory answerGeneration:(uint64_t)answerGeneration {
    os_unfair_lock_lock(&_lock);
    FolderArtEntry *entry = _directories[directory];
    if (entry.resolving == answerGeneration) {
        entry.resolving = 0;
    }
    [self trimLocked];
    os_unfair_lock_unlock(&_lock);
}

// artPath nil settles the folder as having no cover.
- (void)settleEntryLocked:(FolderArtEntry *)entry artPath:(NSString *)artPath {
    entry.artPath = artPath ?: kNoArtMarker;
    entry.readFailures = 0;
    entry.readBlockedWithoutGrant = NO;
    [self touchLocked:entry];
}

- (BOOL)settleDirectory:(NSString *)directory artPath:(NSString *)artPath
               answerGeneration:(uint64_t)answerGeneration withoutGrant:(BOOL)withoutGrant {
    os_unfair_lock_lock(&_lock);
    FolderArtEntry *entry = [self currentEntryLocked:directory answerGeneration:answerGeneration artPath:nil];
    if (entry) {
        [self settleEntryLocked:entry artPath:artPath];
        entry.settledWithoutGrant = withoutGrant;
        [self trimLocked];
    }
    os_unfair_lock_unlock(&_lock);
    return entry != nil;
}

- (BOOL)storeImage:(VibeImage *)image
           inCache:(NSCache<NSString *, VibeImage *> *)cache
         directory:(NSString *)directory
           artPath:(NSString *)artPath
          answerGeneration:(uint64_t)answerGeneration {
    os_unfair_lock_lock(&_lock);
    FolderArtEntry *entry = [self currentEntryLocked:directory answerGeneration:answerGeneration artPath:artPath];
    if (entry) {
        [cache setObject:image forKey:directory];
        [self touchLocked:entry];
    }
    os_unfair_lock_unlock(&_lock);
    return entry != nil;
}

- (BOOL)isAnswerGenerationCurrent:(uint64_t)answerGeneration
             forDirectory:(NSString *)directory
                  artPath:(NSString *)artPath {
    os_unfair_lock_lock(&_lock);
    BOOL current = [self currentEntryLocked:directory answerGeneration:answerGeneration artPath:artPath] != nil;
    os_unfair_lock_unlock(&_lock);
    return current;
}

- (void)postResolutionNotificationForDirectory:(NSString *)directory
                                       answerGeneration:(uint64_t)answerGeneration
                                        artPath:(NSString *)artPath {
    __weak FolderArtResolver *weakSelf = self;
    run_on_main_thread({
        FolderArtResolver *strongSelf = weakSelf;
        if (![strongSelf isAnswerGenerationCurrent:answerGeneration forDirectory:directory artPath:artPath]) {
            return;
        }
        [NSNotificationCenter.defaultCenter postNotificationName:FolderArtDidResolveNotification
                                                          object:strongSelf];
    });
}

#pragma mark - Resolving

// A cell draw asks on every pass, and a playlist of a thousand tracks in one
// folder must produce one job. Worth running whenever the thumbnail is missing
// — unresolved folder, resolved by the header's display-size path, or an
// evicted thumbnail — and worth skipping only for a folder settled as having no
// cover, or one whose job is already out.
//
// One critical section, and deliberately O(1): this is a cell draw, on the main
// thread. Claiming the generation and trimming the history are the job's own
// first acts, on the resolver queue, where they cost nobody a frame.
- (void)scheduleResolveOfDirectory:(NSString *)directory {
    os_unfair_lock_lock(&_lock);
    FolderArtEntry *entry = _directories[directory];
    BOOL skip = entry != nil && (entry.settledEmpty || entry.readBlockedWithoutGrant ||
            entry.resolving != 0 || entry.scheduled);
    if (!skip) {
        [self entryLocked:directory create:YES].scheduled = YES;
    }
    os_unfair_lock_unlock(&_lock);
    if (skip) {
        return;
    }
    __weak FolderArtResolver *weakSelf = self;
    dispatch_async(_queue, ^{
        [weakSelf resolveScheduledDirectory:directory];
    });
}

- (void)resolveScheduledDirectory:(NSString *)directory {
    // Claim first, clear the mark second, so the two overlap: a cell draw
    // landing in between sees the mark, and one landing after sees the claim.
    // Clearing first leaves a gap in which a draw schedules a redundant job.
    uint64_t answerGeneration = [self claimDirectory:directory];
    os_unfair_lock_lock(&_lock);
    _directories[directory].scheduled = NO;
    os_unfair_lock_unlock(&_lock);
    if (answerGeneration == 0) {
        return;
    }
    BOOL settled = NO;
    NSString *artPath = [self resolveDirectory:directory answerGeneration:answerGeneration didSettle:&settled];
    BOOL stored = NO;
    if (artPath) {
        VibeImage *thumbnail = [self loadThumbnailArtAtPath:artPath directory:directory
                                                 answerGeneration:answerGeneration];
        stored = thumbnail != nil && [self storeImage:thumbnail inCache:_thumbnails
                                            directory:directory artPath:artPath answerGeneration:answerGeneration];
    }
    [self releaseDirectory:directory answerGeneration:answerGeneration];
    // Settling is news even when the news is "there is no cover here": the
    // header holds the *previous* track's art while the answer is pending, so
    // without a post for the empty answer a track whose own folder-art load
    // lost this claim race keeps that stale cover on screen.
    if (!settled && !stored) {
        return;
    }
    [self postResolutionNotificationForDirectory:directory
                                         answerGeneration:answerGeneration
                                          artPath:stored ? artPath : nil];
}

// Finds the folder's cover and settles the answer either way. Blocking: a
// handful of stats, or one listing for a bulk-opened folder. Returns the
// cover's path, or nil for a folder with none — and nil too when an invalidate
// overtook the answer, which the next ask resolves afresh. didSettle tells
// those two apart.
- (NSString *)resolveDirectory:(NSString *)directory answerGeneration:(uint64_t)answerGeneration
                     didSettle:(BOOL *)didSettle {
    if (didSettle) {
        *didSettle = NO;
    }
    os_unfair_lock_lock(&_lock);
    FolderArtEntry *entry = [self currentEntryLocked:directory answerGeneration:answerGeneration artPath:nil];
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
        if ([self settleDirectory:directory artPath:nil answerGeneration:answerGeneration withoutGrant:YES] &&
                didSettle) {
            *didSettle = YES;
        }
        return nil;
    }
    NSString *artPath = byListing ? [self artPathByListing:directory]
                                  : [self artPathByProbing:directory];
    if (![self settleDirectory:directory artPath:artPath answerGeneration:answerGeneration withoutGrant:NO]) {
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
                 answerGeneration:(uint64_t)answerGeneration {
    // Discovery and reading are separate permission edges. A donated listing
    // can outlive the security scope that made it, and decoded images can be
    // evicted after the user removes a grant. Recheck immediately before the
    // only cover-file read so background artwork never opens a protected path
    // without an active scope.
    os_unfair_lock_lock(&_lock);
    uint64_t accessGeneration = _accessGeneration;
    os_unfair_lock_unlock(&_lock);
    if (!_accessProvider(directory)) {
        os_unfair_lock_lock(&_lock);
        FolderArtEntry *entry = [self currentEntryLocked:directory
                                                answerGeneration:answerGeneration
                                                 artPath:artPath];
        if (entry && _accessGeneration == accessGeneration) {
            entry.readBlockedWithoutGrant = YES;
            [self touchLocked:entry];
        }
        os_unfair_lock_unlock(&_lock);
        LogDebug(@"No folder grant for %@ — skipping folder art read", directory);
        return nil;
    }
    LogDebug(@"Loading folder art %@", artPath);
    NSData *data = _dataReader(artPath);
    BOOL settledArtless = NO;
    os_unfair_lock_lock(&_lock);
    FolderArtEntry *entry = [self currentEntryLocked:directory answerGeneration:answerGeneration artPath:artPath];
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
            settledArtless = YES;
        }
        else {
            LogWarn(@"Folder art at %@ could not be read; keeping it for another try", artPath);
        }
    }
    os_unfair_lock_unlock(&_lock);
    // "It has none" is an answer and is posted too (header contract): the
    // entry held a cover path until this settle, so this is always a
    // transition, never a re-confirmation.
    if (settledArtless) {
        [self postResolutionNotificationForDirectory:directory answerGeneration:answerGeneration artPath:nil];
    }
    return data;
}

// Unlike a read failure this is permanent for these bytes, so the folder counts
// as having no cover rather than costing every track in it a fresh decode.
- (VibeImage *)decodeArtData:(NSData *)data
                    atPath:(NSString *)artPath
                 directory:(NSString *)directory
                  answerGeneration:(uint64_t)answerGeneration
              maxPixelSize:(CGFloat)maxPixelSize {
    VibeImage *image = _decoder(data, maxPixelSize);
    if (image) {
        return image;
    }
    LogWarn(@"Folder art at %@ could not be decoded", artPath);
    os_unfair_lock_lock(&_lock);
    FolderArtEntry *entry = [self currentEntryLocked:directory answerGeneration:answerGeneration artPath:artPath];
    if (entry) {
        [self settleEntryLocked:entry artPath:nil];
        [_thumbnails removeObjectForKey:directory];
        [_displayImages removeObjectForKey:directory];
    }
    os_unfair_lock_unlock(&_lock);
    // "It has none" is an answer and is posted too (header contract): the
    // entry held a cover path until this settle, so this is always a
    // transition, never a re-confirmation.
    if (entry) {
        [self postResolutionNotificationForDirectory:directory answerGeneration:answerGeneration artPath:nil];
    }
    return nil;
}

- (VibeImage *)loadThumbnailArtAtPath:(NSString *)artPath
                          directory:(NSString *)directory
                           answerGeneration:(uint64_t)answerGeneration {
    NSData *data = [self readArtAtPath:artPath directory:directory answerGeneration:answerGeneration];
    return data ? [self decodeArtData:data atPath:artPath directory:directory
                             answerGeneration:answerGeneration maxPixelSize:kVibeThumbnailArtDimension] : nil;
}

// The header's size, plus the row thumbnail off the same bytes: read once,
// decode twice, rather than reading again the moment a row for the same folder
// draws. Only this direction is free — 128px cannot be enlarged back to 1024 —
// so a folder whose rows draw before its header still pays two reads.
- (VibeImage *)loadDisplayArtAtPath:(NSString *)artPath
                        directory:(NSString *)directory
                         answerGeneration:(uint64_t)answerGeneration {
    NSData *data = [self readArtAtPath:artPath directory:directory answerGeneration:answerGeneration];
    if (!data) {
        return nil;
    }
    VibeImage *display = [self decodeArtData:data atPath:artPath directory:directory
                                  answerGeneration:answerGeneration maxPixelSize:kVibeDisplayArtDimension];
    if (!display) {
        return nil;
    }
    if (![_thumbnails objectForKey:directory]) {
        // Straight to the decoder: the display decode just proved these bytes
        // are an image, so a failure here is about the size alone and must not
        // settle the folder.
        VibeImage *thumbnail = _decoder(data, kVibeThumbnailArtDimension);
        if (thumbnail) {
            [self storeImage:thumbnail inCache:_thumbnails
                   directory:directory artPath:artPath answerGeneration:answerGeneration];
        }
    }
    return [self storeImage:display inCache:_displayImages
                  directory:directory artPath:artPath answerGeneration:answerGeneration] ? display : nil;
}

@end
