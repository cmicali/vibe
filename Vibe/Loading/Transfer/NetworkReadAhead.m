//
//  NetworkReadAhead.m
//  Vibe
//

#import "NetworkReadAhead.h"
#import "AudioFileOpenRules.h"
#import "CloudFileAvailability.h"
#if DEBUG
#import "AudioFileHandle+Debug.h"
#endif

#include <fcntl.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <sys/mount.h>
#include <sys/stat.h>

// The read-ahead (VibeReadAheadRun) fetches 256 KB blocks up to 8 MB ahead of
// the reader. It keeps one block behind the reader's. An MP3 seek's preroll
// and dr_flac's bisection read back over it.
enum { kVibeReadAheadBlock = 256 * 1024 };
static const uint64_t kVibeReadAheadSpan = 8 * 1024 * 1024;
// A failed read is tried again this long after, until the handle goes.
static const NSTimeInterval kVibeReadAheadRetrySeconds = 1;
// Read-ahead threads whose handle is gone while they are still inside a read,
// a dead mount's or a slow one's. At this many, a new read-ahead open waits
// for one to exit before it makes a thread.
static const NSInteger kVibeReadAheadOrphanLimit = 8;

// TRAP: both edges of a read-ahead's end run under this lock: its handle's
// dealloc and its thread's exit. A thread still running at the dealloc is an
// orphan until it exits, and no other thread ever is. The two share one
// flags cell. The second edge frees it.
static os_unfair_lock sReadAheadLock = OS_UNFAIR_LOCK_INIT;
static NSInteger sOrphanedReadAheads;
enum { kVibeReadAheadHandleGone = 1, kVibeReadAheadThreadGone = 2 };

#if DEBUG
// TRAP: set on a test's thread, read on opens and read-ahead threads. An
// unlocked read of a block global is a retain racing a release.
static os_unfair_lock sDebugLock = OS_UNFAIR_LOCK_INIT;
static NSNumber *(^sDebugMountRule)(NSURL *);
static int (^sDebugBeforeRead)(NSURL *, uint64_t, uint64_t);
static _Atomic NSInteger sDebugLiveReadAheads;
static _Atomic double sDebugRetryScale = 1;
#endif

static NSTimeInterval VibeReadAheadRetryPause(void) {
#if DEBUG
    return kVibeReadAheadRetrySeconds * atomic_load(&sDebugRetryScale);
#else
    return kVibeReadAheadRetrySeconds;
#endif
}

// Whether `url` reads ahead: the kernel's mount table says its mount is a
// network one. Never a stat of the path: a dead mount holds a stat for its
// timeout. A table that cannot be read is the direct road.
BOOL VibeNetworkReadAheadApplies(NSURL *url, NSString **mount) {
#if DEBUG
    os_unfair_lock_lock(&sDebugLock);
    NSNumber *(^rule)(NSURL *) = sDebugMountRule;
    os_unfair_lock_unlock(&sDebugLock);
    NSNumber *forced = rule ? rule(url) : nil;
    if (forced) {
        *mount = @"a mount the debug rule chose";
        return forced.boolValue;
    }
#endif
    int count = getfsstat(NULL, 0, MNT_NOWAIT);
    struct statfs *mounts = count > 0 ? calloc((size_t)count, sizeof(*mounts)) : NULL;
    count = mounts ? getfsstat(mounts, count * (int)sizeof(*mounts), MNT_NOWAIT) : -1;
    const struct statfs *share = count > 0 ? VibeMountReadsAhead(mounts, count, url.path) : NULL;
    if (share) {
        *mount = @(share->f_mntonname);
    }
    free(mounts);
    return share != NULL;
}

static NSInteger VibeOrphanedReadAheads(void) {
    os_unfair_lock_lock(&sReadAheadLock);
    NSInteger orphans = sOrphanedReadAheads;
    os_unfair_lock_unlock(&sReadAheadLock);
    return orphans;
}

// Waits while the orphans are at their limit. NO once `interrupted` answers
// YES.
BOOL VibeNetworkReadAheadAwaitRoom(NSString *name, BOOL (^interrupted)(void)) {
    BOOL logged = NO;
    while (VibeOrphanedReadAheads() >= kVibeReadAheadOrphanLimit) {
        if (interrupted()) {
            return NO;
        }
        if (!logged) {
            LogWarn(@"Read-ahead: %@ waits: %ld reads of closed files are stuck", name, (long)kVibeReadAheadOrphanLimit);
            logged = YES;
        }
        [NSThread sleepForTimeInterval:kVibeReadAheadOpenPollSeconds];
    }
    return YES;
}

// One edge of a read-ahead's end: the handle's dealloc, or the thread's exit
// after its last syscall. When the handle's edge comes first, the thread is
// an orphan until its own edge.
static void VibeReadAheadEnd(uint8_t *flags, uint8_t edge) {
    os_unfair_lock_lock(&sReadAheadLock);
    BOOL second = *flags != 0;
    *flags |= edge;
    if (edge == kVibeReadAheadHandleGone && !second) {
        sOrphanedReadAheads++;
    } else if (edge == kVibeReadAheadThreadGone && second) {
        sOrphanedReadAheads--;
    }
    os_unfair_lock_unlock(&sReadAheadLock);
    if (second) {
        free(flags);
    }
#if DEBUG
    if (edge == kVibeReadAheadThreadGone) {
        atomic_fetch_sub(&sDebugLiveReadAheads, 1);
    }
#endif
}

// What ends a read-ahead's availability when its handle lets it go.
static NSError *VibeReadAheadClosedError(NSURL *url) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:ECANCELED
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ was closed", url.lastPathComponent]}];
}

// The direct road's flags, for the same reason (its TRAP: a FIFO with no
// writer returns at once), then blocking reads. Nil, or the open's failure
// as the direct road reports it. *info is the file's fstat.
static NSError *VibeReadAheadOpen(const char *path, NSString *name, int *descriptor, struct stat *info) {
    *descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (*descriptor < 0) {
        return VibeCouldNotOpenError(name, errno);
    }
    NSError *error = nil;
    int flags;
    if (fstat(*descriptor, info) != 0 || !S_ISREG(info->st_mode) || info->st_size <= 0) {
        error = VibeNoAudioError(name);
    }
    else if ((flags = fcntl(*descriptor, F_GETFL)) < 0 || fcntl(*descriptor, F_SETFL, flags & ~O_NONBLOCK) != 0) {
        error = VibeCouldNotOpenError(name, errno);
    }
    if (error) {
        close(*descriptor);
        *descriptor = -1;
    }
    return error;
}

// One pread, through the debug seam's hook. An error leaves errno set.
static ssize_t VibeReadAheadPread(int descriptor, NSURL *url, uint8_t *buffer, uint64_t count, uint64_t offset) {
#if DEBUG
    os_unfair_lock_lock(&sDebugLock);
    int (^beforeRead)(NSURL *, uint64_t, uint64_t) = sDebugBeforeRead;
    os_unfair_lock_unlock(&sDebugLock);
    int injected = beforeRead ? beforeRead(url, offset, count) : 0;
    if (injected != 0) {
        errno = MAX(injected, 0);
        return injected < 0 ? 0 : -1;
    }
#endif
    return VibePread(descriptor, buffer, (size_t)count, (off_t)offset);
}

// The read-ahead's thread: the one thread that enters the kernel for its
// file. It fetches a range a blocked wait wants first, rounded out to whole
// blocks, else the next block after the reader's up to the span ahead, unless
// paused. It installs each in the availability and drops what lies outside
// the reader's span. A failed read is tried again after a pause, reopened,
// until the availability finishes. A reopened file that changed fails the
// availability. A read that finds nothing short of the size is the end only
// when the file is now that short. TRAP: it retains the availability only,
// never its handle.
// The handle's dealloc can then finish the availability and end it. TRAP:
// nothing here holds the availability's lock across open, pread or close.
// The player queue takes that lock through interruptReads and wakeWaiters.
// TRAP: a no-part-file availability is never finished with nil. Complete
// would send its readers to a disk it never wrote.
static void VibeReadAheadRun(CloudFileAvailability *availability, NSURL *url, NSString *mount, uint8_t *flags) {
    NSString *name = url.lastPathComponent;
    char *path = strdup(url.fileSystemRepresentation);
    int descriptor = -1;
    // The file as the read-ahead knows it. A reopen must find the same one.
    struct stat known = {0};
    NSError *failure = path ? VibeReadAheadOpen(path, name, &descriptor, &known) : VibeCouldNotOpenError(name, ENOMEM);
    if (failure) {
        free(path);
        // First. The handle the failed open lets go then never counts it.
        VibeReadAheadEnd(flags, kVibeReadAheadThreadGone);
        [availability finishWithError:failure];
        return;
    }
    [availability noteSize:(uint64_t)known.st_size];
    LogInfo(@"Read-ahead: %@ on %@, %lld bytes", name, mount, (long long)known.st_size);
    NSUInteger errors = 0;
    BOOL failing = NO;
    NSDate *until = NSDate.distantPast;
    for (;;) @autoreleasepool {
        uint64_t wantedOffset = 0, wantedLength = 0, position = 0;
        if (![availability waitForWorkUntil:until wanted:&wantedOffset length:&wantedLength readerPosition:&position]) {
            break;
        }
        until = NSDate.distantFuture;
        uint64_t end = availability.size;
        uint64_t wantedEnd = MIN(wantedOffset + wantedLength, end);
        uint64_t start = 0, stop = 0;
        uint64_t held = wantedLength > 0 ? [availability heldEndAt:wantedOffset] : end;
        if (held < wantedEnd) {
            // A partial read can leave the held end inside the range. The
            // fetch then starts there and fetches no byte twice.
            start = held == wantedOffset ? held / kVibeReadAheadBlock * kVibeReadAheadBlock : held;
            stop = MIN((wantedEnd + kVibeReadAheadBlock - 1) / kVibeReadAheadBlock * kVibeReadAheadBlock, end);
        } else if (!availability.readAheadPaused) {
            start = [availability heldEndAt:position / kVibeReadAheadBlock * kVibeReadAheadBlock];
            stop = start < position + kVibeReadAheadSpan ? MIN((start / kVibeReadAheadBlock + 1) * kVibeReadAheadBlock, end) : 0;
        }
        if (stop <= start) {
            continue;
        }
        NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)(stop - start)];
        uint64_t got = 0;
        ssize_t count = 0;
        while (got < stop - start
                && (count = VibeReadAheadPread(descriptor, url, (uint8_t *)bytes.mutableBytes + got, stop - start - got, start + got)) > 0) {
            got += (uint64_t)count;
        }
        int readError = count < 0 ? errno : 0;
        if (got > 0) {
            bytes.length = (NSUInteger)got;
            [availability installBlock:bytes atOffset:start];
            uint64_t behind = position / kVibeReadAheadBlock * kVibeReadAheadBlock;
            behind = behind >= kVibeReadAheadBlock ? behind - kVibeReadAheadBlock : 0;
            [availability dropBlocksOutsideRangeAt:behind length:position + kVibeReadAheadSpan - behind];
        }
        until = NSDate.distantPast;
        // TRAP: a network mount can read 0 bytes short of the size while it
        // reconnects. That is the end only when the file is now that short.
        // Any other 0 is a failed read, logged as EIO and retried. Taken as
        // the end, it ends the track early.
        if (count == 0) {
            struct stat now;
            readError = fstat(descriptor, &now) != 0 ? errno : (uint64_t)now.st_size > start + got ? EIO : 0;
            if (readError == 0) {
                [availability noteShortenedEnd:start + got];
                known = now;
            }
        }
        if (readError == 0) {
            failing = NO;
            continue;
        }
        errors++;
        if (!failing) {
            LogWarn(@"Read-ahead: reading %@ at %llu failed: %s; retrying every %.1f s", name, start + got,
                    strerror(readError), VibeReadAheadRetryPause());
            failing = YES;
        }
        // A timed wait on the availability. A finish ends the pause at once.
        NSDate *retry = [NSDate dateWithTimeIntervalSinceNow:VibeReadAheadRetryPause()];
        BOOL running = YES;
        while (running && retry.timeIntervalSinceNow > 0) {
            running = [availability waitForWorkUntil:retry wanted:&wantedOffset length:&wantedLength readerPosition:&position];
        }
        if (!running) {
            break;
        }
        close(descriptor);
        // A failed reopen leaves -1. That fails the next read and pauses
        // again. A file replaced while the share was away fails the
        // availability. Its bytes would otherwise mix with the old file's
        // blocks. Size and mtime tell the two apart. The inode and st_dev do
        // not. Some SMB servers renumber a file across a reconnect, and a
        // remount moves st_dev.
        struct stat reopened;
        if (VibeReadAheadOpen(path, name, &descriptor, &reopened) == nil
                && (reopened.st_size != known.st_size || reopened.st_mtimespec.tv_sec != known.st_mtimespec.tv_sec
                    || reopened.st_mtimespec.tv_nsec != known.st_mtimespec.tv_nsec)) {
            LogWarn(@"Read-ahead: %@ changed while it failed: %lld bytes, was %lld", name, (long long)reopened.st_size,
                    (long long)known.st_size);
            [availability finishWithError:[NSError errorWithDomain:NSPOSIXErrorDomain code:ESTALE userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ changed while it was read", name]}]];
            break;
        }
    }
    if (descriptor >= 0) {
        close(descriptor);
    }
    free(path);
    LogInfo(@"Read-ahead: %@ ended after %lu failed reads", name, (unsigned long)errors);
    VibeReadAheadEnd(flags, kVibeReadAheadThreadGone);
}

CloudFileAvailability *VibeNetworkReadAheadStart(NSURL *url, NSString *mount, uint8_t **end) {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    uint8_t *flags = calloc(1, sizeof(*flags));
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        VibeReadAheadRun(availability, url, mount, flags);
    }];
    thread.name = @"com.vibe.readahead";
    // Fixed, not the opener's: a prefetch opens at utility and then becomes
    // the voice the decode reads.
    thread.qualityOfService = NSQualityOfServiceUserInitiated;
    *end = flags;
#if DEBUG
    atomic_fetch_add(&sDebugLiveReadAheads, 1);
#endif
    [thread start];
    return availability;
}

void VibeNetworkReadAheadClose(CloudFileAvailability *availability, NSURL *url) {
    [availability finishWithError:VibeReadAheadClosedError(url)];
}

void VibeNetworkReadAheadHandleGone(CloudFileAvailability *availability, NSURL *url, uint8_t *end) {
    VibeNetworkReadAheadClose(availability, url);
    VibeReadAheadEnd(end, kVibeReadAheadHandleGone);
}

#if DEBUG

void VibeNetworkReadAheadDebugSetMountRule(NSNumber *(^rule)(NSURL *)) {
    NSNumber *(^copied)(NSURL *) = [rule copy];
    os_unfair_lock_lock(&sDebugLock);
    sDebugMountRule = copied;
    os_unfair_lock_unlock(&sDebugLock);
}

void VibeNetworkReadAheadDebugSetBeforeRead(int (^beforeRead)(NSURL *, uint64_t, uint64_t)) {
    int (^copied)(NSURL *, uint64_t, uint64_t) = [beforeRead copy];
    os_unfair_lock_lock(&sDebugLock);
    sDebugBeforeRead = copied;
    os_unfair_lock_unlock(&sDebugLock);
}

void VibeNetworkReadAheadDebugSetRetryScale(double scale) {
    atomic_store(&sDebugRetryScale, scale);
}

NSInteger VibeNetworkReadAheadDebugLive(void) {
    return atomic_load(&sDebugLiveReadAheads);
}

NSInteger VibeNetworkReadAheadDebugOrphaned(void) {
    return VibeOrphanedReadAheads();
}

#endif
