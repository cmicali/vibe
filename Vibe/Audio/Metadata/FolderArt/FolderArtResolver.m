//
// FolderArtResolver.m
// Vibe
//
// The lock covers _directories only and is never held across a stat, read or
// decode: main takes it on every cell draw. Only background paths mutate or
// trim the history, except scheduleResolveOfDirectory:'s O(1) mark.
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
#import "FolderAccessManager.h"
#endif
#import "PlatformImage.h"

#import <os/lock.h>
#import <stdatomic.h>

NSNotificationName const FolderArtDidResolveNotification = @"FolderArtDidResolveNotification";

static const NSUInteger kThumbnailCacheLimit = 64;
// Enough that alternating between a few albums does not re-decode each time.
static const NSUInteger kDisplayCacheLimit = 4;
// A library walk can name hundreds of thousands of folders.
static const NSUInteger kRecordedDirectoryLimit = 4096;
static const NSUInteger kRecordedDirectoryFloor = 3072;

// A read failure is momentary and retried, but a file that never opens must
// not cost every cell draw an open.
static const uint8_t kMaxArtReadFailures = 3;

// The settled "none".
static NSString *const kNoArtMarker = @"";

#pragma mark - The resolver

@implementation FolderArtResolver {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, FolderArtEntry *> *_directories;
    uint64_t _nextAnswerGeneration;
    uint64_t _accessClock;
    // A denial older than a grant change must not park a path it re-armed.
    // Guarded by _lock.
    uint64_t _accessGeneration;
    NSCache<NSString *, VibeImage *> *_thumbnails;
    NSCache<NSString *, VibeImage *> *_displayImages;
    dispatch_queue_t _queue;
    // useFolderArt, cached: every accessor gates on it on every cell draw.
    // Only init, folderArtSettingDidChange and invalidate write it.
    atomic_bool _enabledCache;
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
        // Unreachable on iOS; off if that ever changes.
        return NO;
#endif
    } accessProvider:^BOOL(NSString *directory) {
#if TARGET_OS_OSX
        return [FolderAccessManager.sharedInstance canReadInsideDirectory:directory];
#else
        // Everything the app can name is inside FolderSession's one scope.
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
        atomic_init(&_enabledCache, enabledProvider());
        // Serial: one folder at a time, so scrolling is no disk storm.
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
    // A settled cover decodes without the resolve claim, so a background
    // resolve cannot send the header away empty; the pin keeps eviction off.
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
            return nil;
        }
        // Read before the decode, because the decode is what fills it.
        BOOL thumbnailWasMissing = [_thumbnails objectForKey:directory] == nil;
        VibeImage *display = [self loadDisplayArtAtPath:settled directory:directory
                                             answerGeneration:settledAnswerGeneration];
        os_unfair_lock_lock(&_lock);
        // An invalidate may have replaced the entry; the guard covers it.
        FolderArtEntry *pinned = _directories[directory];
        if (pinned.decoding > 0) {
            pinned.decoding -= 1;
        }
        os_unfair_lock_unlock(&_lock);
        // Post only when this decode also filled a missing thumbnail: a
        // re-decode after display-cache eviction changes nothing for the rows.
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
    // Rows that asked during this claim skipped their own job, so this owner
    // posts for them: on pixels, or on a settled "none". An unreadable cover
    // posts nothing; its retry will. artPath fences a cover replaced mid-decode,
    // so it names what was drawn; nil only for "none".
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
    // Read-only: on main; the resolve touches the entry itself.
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
        // The same answer keeps its generation, so its images stay valid.
        if (entry.answerGeneration != 0 && [entry.artPath isEqualToString:artPath]) {
            continue;
        }
        entry.answerGeneration = [self newAnswerGenerationLocked];
        entry.artPath = artPath;
        entry.resolving = 0;
        entry.readFailures = 0;
        entry.readBlockedWithoutGrant = NO;
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
            continue;
        }
        [self entryLocked:directory create:YES].preferListing = YES;
    }
    [self trimLocked];
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Invalidation

- (void)folderArtSettingDidChange {
    // TRAP: outside init and the test-only invalidate, the only refresh of the
    // cached useFolderArt, so a writer that skips
    // VibeSettingsLiveEffectFolderArt is never observed. Not a full wipe.
    atomic_store_explicit(&_enabledCache, _enabledProvider(), memory_order_relaxed);
    [_thumbnails removeAllObjects];
    [_displayImages removeAllObjects];
}

- (void)invalidate {
    atomic_store_explicit(&_enabledCache, _enabledProvider(), memory_order_relaxed);
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *forgotten = [NSMutableArray array];
    for (NSString *directory in _directories) {
        FolderArtEntry *entry = _directories[directory];
        [entry forgetSettledAnswer];
        entry.preferListing = NO;
        // Busy entries stay: work in flight unpins them.
        if (!entry.busy) {
            [forgotten addObject:directory];
        }
    }
    [_directories removeObjectsForKeys:forgotten];
    [_thumbnails removeAllObjects];
    [_displayImages removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

// TRAP: not a full wipe: only no-grant answers are forgotten and every cover
// path survives (an open's grant lands just after its walk). invalidate, the
// wipe, is test-only.
- (void)invalidateDirectoriesSettledWithoutGrant {
    os_unfair_lock_lock(&_lock);
    _accessGeneration++;
    for (NSString *directory in _directories) {
        FolderArtEntry *entry = _directories[directory];
        if (entry.settledWithoutGrant) {
            [entry forgetSettledAnswer];
        }
        // The next read rechecks access before touching the file.
        entry.readBlockedWithoutGrant = NO;
    }
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Entries

- (BOOL)folderArtEnabled {
    return atomic_load_explicit(&_enabledCache, memory_order_relaxed);
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

// nil when an invalidate or re-listing overtook the caller's work: the
// generation, or the named cover path, moved.
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

// One batch down to the floor, so the sort under the lock runs once per
// (limit - floor) new folders, not per folder.
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
    // Clocks are unique, so the cutoff selects exactly count entries.
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

// A thousand rows in one folder must produce one job. O(1) on main; the claim
// and trim are the job's own first acts.
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
    // Claim before clearing the mark, so a draw always sees one of them.
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
    // "None" posts too: the header holds the previous track's art until an
    // answer arrives.
    if (!settled && !stored) {
        return;
    }
    [self postResolutionNotificationForDirectory:directory
                                         answerGeneration:answerGeneration
                                          artPath:stored ? artPath : nil];
}

// Blocking. nil for "none" and for an answer an invalidate overtook; didSettle
// tells them apart.
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
    // Unasked-for work must not raise a consent panel, so an ungranted folder
    // is not probed. A later grant clears this answer
    // (MainPlayerController.grantedFoldersDidChange:).
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

// A lone file: at most kVibeFolderArtStatProbeCount stats, best first.
- (NSString *)artPathByProbing:(NSString *)directory {
    NSArray<NSString *> *candidates = VibeFolderArtCandidateFilenames();
    NSUInteger probes = MIN(kVibeFolderArtStatProbeCount, candidates.count);
    for (NSUInteger i = 0; i < probes; i++) {
        NSString *path = [directory stringByAppendingPathComponent:candidates[i]];
        if (_fileInfo(path, NULL)) {
            return path;
        }
    }
    return nil;
}

// A bulk open: one listing finds every spelling. A folder drop settles through
// its walk instead, unless its grant arrived late.
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

// The one place a cover file is opened. A read failure is momentary: the
// cover is kept and retried up to kMaxArtReadFailures, unlike a decode
// failure, which settles the folder.
- (NSData *)readArtAtPath:(NSString *)artPath
                directory:(NSString *)directory
                 answerGeneration:(uint64_t)answerGeneration {
    // A donated path can outlive its scope, so access is rechecked right
    // before the read.
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
    // Always a transition: the entry held a cover path until now.
    if (settledArtless) {
        [self postResolutionNotificationForDirectory:directory answerGeneration:answerGeneration artPath:nil];
    }
    return data;
}

// Permanent for these bytes: the folder settles as having none.
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
    // Always a transition: the entry held a cover path until now.
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

// Also fills the row thumbnail from the same bytes: read once, decode twice.
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
        // Straight to the decoder: these bytes just decoded, so a failure
        // here must not settle the folder.
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
