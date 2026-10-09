//
//  AudioFileOpenRules.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "NSURLUtil.h"

#include <string.h>
#include <sys/mount.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeAudioFileOpenDeliveryState) {
    VibeAudioFileOpenDeliveryWaiting = 0,
    VibeAudioFileOpenDeliveryRunning,
    VibeAudioFileOpenDeliveryDetached,
};

// The caller serializes access to state. Delivery and detachment race for the
// one Waiting transition; whichever changes it first owns the outcome.
static inline BOOL VibeAudioFileOpenBeginDelivery(
        VibeAudioFileOpenDeliveryState *state) {
    if (*state != VibeAudioFileOpenDeliveryWaiting) {
        return NO;
    }
    *state = VibeAudioFileOpenDeliveryRunning;
    return YES;
}

static inline BOOL VibeAudioFileOpenDetachDelivery(
        VibeAudioFileOpenDeliveryState *state) {
    if (*state != VibeAudioFileOpenDeliveryWaiting) {
        return NO;
    }
    *state = VibeAudioFileOpenDeliveryDetached;
    return YES;
}

// One spelling of a file path for single-flight ownership, without I/O.
// TRAP: URLByStandardizingPath stats the target, so it can stall the player
// or state queue before the bounded probe begins. Compare spelling alone.
static inline NSString *VibeStandardizedAudioOpenPath(NSURL *url) {
    if (url.isFileURL) {
        return VibeComparablePath(url.path) ?: @"";
    }
    return url.absoluteString ?: @"";
}

// The bytes at a file's end its open reads, with room, for a stream to fetch
// ahead of its download (the Dropbox mirror's tail window); 0 for none. Every
// open that reads past its head reads one region at the end (measured,
// docs/future/streaming-any-source.md). An MP3's ID3v1 check reads 4–128 bytes,
// an APE footer a few KB more, and a FLAC with no length 64 KB. 128 KB is twice
// the largest. A container of chunks reads further. Its open walks every chunk
// header to the end, so the window must reach the last one. In an MP4 that is
// the moov, which grows with the length: 4 bytes per 1024-sample AAC frame,
// ~10 KB a minute (61 KB at 6 minutes, 608 KB at 60), against 960 KB a minute
// of 128 kbps audio. A 32nd of the file then holds the index of any AAC at
// 43 kbps or more. In an AIFF, a WAV, a W64, or a CAF it is any chunk after
// the audio, most often a tag with its cover (235 KB on a measured AIFF).
// The floor is about twice that, and room for a short track's moov with its
// cover. The cap is a two-hour mix's 1.2 MB with a quarter's headroom,
// reached from 48 MB. A longer index-last M4A, or a larger chunk on a shorter
// file, waits for its download. A file no bigger than twice its window takes
// none: a download from its start reaches the tail as soon.
static inline uint64_t VibeAudioFileTailWindowBytes(NSString *extension, uint64_t size) {
    static const uint64_t kSmall = 128 * 1024, kChunkedFloor = 512 * 1024, kChunkedCap = 1536 * 1024;
    BOOL chunked = [@[@"m4a", @"m4b", @"m4r", @"mp4", @"qta", @"aif", @"aiff", @"wav", @"wave", @"bwf", @"w64", @"caf"]
            containsObject:extension.lowercaseString];
    uint64_t window = chunked ? MIN(kChunkedCap, MAX(kChunkedFloor, size / 32)) : kSmall;
    return size > 2 * window ? window : 0;
}

// One spelling for a mount and a path, made without asking the disk. A
// leading /System/Volumes/Data is dropped. The data volume's firmlinks make
// that prefix and the root one place. A path that then starts with /var or
// /tmp is spelled under /private. Those two are symlinks into it. Truncated
// to `capacity`.
static inline void VibeMountSpelling(const char *path, char *spelled, size_t capacity) {
    static const char kData[] = "/System/Volumes/Data";
    const size_t data = sizeof(kData) - 1;
    if (strncmp(path, kData, data) == 0 && (path[data] == '/' || path[data] == '\0')) {
        path = path[data] == '\0' ? "/" : path + data;
    }
    BOOL aliased = (strncmp(path, "/var", 4) == 0 || strncmp(path, "/tmp", 4) == 0)
            && (path[4] == '/' || path[4] == '\0');
    snprintf(spelled, capacity, "%s%s", aliased ? "/private" : "", path);
}

// The index of the mount holding `path` in a getfsstat table: the longest
// mount name that is a whole-component prefix of it. -1 for none.
static inline int VibeMountHoldingPath(const struct statfs *_Nullable mounts, int count, const char *path) {
    char spelledPath[MNAMELEN + 16], spelledMount[MNAMELEN + 16];
    VibeMountSpelling(path, spelledPath, sizeof(spelledPath));
    int best = -1;
    size_t bestLength = 0;
    for (int i = 0; i < count; i++) {
        VibeMountSpelling(mounts[i].f_mntonname, spelledMount, sizeof(spelledMount));
        size_t length = strlen(spelledMount);
        while (length > 1 && spelledMount[length - 1] == '/') {
            length--;
        }
        BOOL root = length == 1 && spelledMount[0] == '/';
        BOOL holds = root ? spelledPath[0] == '/'
                          : strncmp(spelledPath, spelledMount, length) == 0
                                    && (spelledPath[length] == '/' || spelledPath[length] == '\0');
        if (holds && (best < 0 || length > bestLength)) {
            best = i;
            bestLength = length;
        }
    }
    return best;
}

// Whether a file reads ahead: YES when the mount holding it is a network one.
// A network mount is any mount not flagged MNT_LOCAL. No mount, or an empty
// table, is NO: the direct road.
static inline BOOL VibeMountReadsAhead(const struct statfs *_Nullable mounts, int count, const char *path) {
    int index = VibeMountHoldingPath(mounts, count, path);
    return index >= 0 && (mounts[index].f_flags & MNT_LOCAL) == 0;
}

NS_ASSUME_NONNULL_END
