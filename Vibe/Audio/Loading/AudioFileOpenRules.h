//
//  AudioFileOpenRules.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "NSURLUtil.h"

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
// docs/future/streaming-any-source.md): an MP3's ID3v1 check 4–128 bytes, an APE
// footer a few KB more, a WAV or AIFF with its fmt last 24 bytes, a FLAC with
// no length 64 KB, so 128 KB is twice the largest. An MP4's is its moov, which
// grows with the length: 4 bytes per 1024-sample AAC frame, ~10 KB a minute
// (61 KB at 6 minutes, 608 KB at 60) against 960 KB a minute of 128 kbps
// audio, so a 32nd of the file holds the index of any AAC at 43 kbps or more.
// The cap is a two-hour mix's 1.2 MB with a quarter's headroom; a longer
// index-last M4A waits for its download. The floor leaves a short track's
// moov room for the cover it carries. A file no bigger than twice its window
// takes none: a download from its start reaches the tail as soon.
static inline uint64_t VibeAudioFileTailWindowBytes(NSString *extension, uint64_t size) {
    static const uint64_t kSmall = 128 * 1024, kMP4Floor = 512 * 1024, kMP4Cap = 1536 * 1024;
    BOOL mp4 = [@[@"m4a", @"m4b", @"m4r", @"mp4", @"qta"] containsObject:extension.lowercaseString];
    uint64_t window = mp4 ? MIN(kMP4Cap, MAX(kMP4Floor, size / 32)) : kSmall;
    return size > 2 * window ? window : 0;
}

// A spelling for comparing a mount's name and a path, from the string alone:
// VibeAliasFreePath's, ending in exactly one slash. The slash makes a prefix
// whole components. It also spells the data volume's own mount as the root.
static inline NSString *VibeMountSpelling(NSString *path) {
    NSUInteger end = path.length;
    while (end > 0 && [path characterAtIndex:end - 1] == '/') {
        end--;
    }
    return VibeAliasFreePath([[path substringToIndex:end] stringByAppendingString:@"/"]);
}

// The index of the mount holding `path` in a getfsstat table: the longest
// mount name that is a whole-component prefix of it. -1 for none.
static inline int VibeMountHoldingPath(const struct statfs *_Nullable mounts, int count, NSString *path) {
    NSString *spelledPath = VibeMountSpelling(path);
    int best = -1;
    NSUInteger bestLength = 0;
    for (int i = 0; i < count; i++) {
        NSString *name = [NSString stringWithUTF8String:mounts[i].f_mntonname];
        NSString *mount = name ? VibeMountSpelling(name) : nil;
        if (mount && [spelledPath hasPrefix:mount] && (best < 0 || mount.length > bestLength)) {
            best = i;
            bestLength = mount.length;
        }
    }
    return best;
}

// The network mount a file reads ahead from: the mount holding it, when that
// is a network one. A network mount is any mount not flagged MNT_LOCAL. NULL
// is the direct road, as is no mount or an empty table.
static inline const struct statfs *_Nullable VibeMountReadsAhead(const struct statfs *_Nullable mounts, int count,
                                                                 NSString *path) {
    int index = VibeMountHoldingPath(mounts, count, path);
    return index >= 0 && (mounts[index].f_flags & MNT_LOCAL) == 0 ? &mounts[index] : NULL;
}

NS_ASSUME_NONNULL_END
