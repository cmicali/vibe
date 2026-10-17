//
//  AudioFileOpenRules.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "FilePaths.h"

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
// TRAP: URLByStandardizingPath stats a path that starts with /private or holds
// "..", so it can stall the player or state queue before the bounded probe
// begins. Every path an iOS provider hands over starts with /private. Compare
// spelling alone.
static inline NSString *VibeStandardizedAudioOpenPath(NSURL *url) {
    if (url.isFileURL) {
        return VibeComparablePath(url.path) ?: @"";
    }
    return url.absoluteString ?: @"";
}

// The bytes at a file's end its open reads, with room, for a stream to fetch
// ahead of its download (a placeholder store's tail window); 0 for none. Every
// open that reads past its head reads one region at the end (measured,
// docs/future/streaming-any-source.md). Under Apple's MP3 decoder, CoreAudio's
// parser opens an MP3 and its ID3v1 check reads 4–128 bytes, an APE footer a
// few KB more. dr_mp3's open reads none. A FLAC with no length or an Ogg
// Vorbis file reads 64 KB. 128 KB is twice the largest. A container of chunks reads further.
// Its open walks every chunk header to the end, so the window must reach the
// last one. In an MP4 that is the moov, which grows with the length: 4 bytes
// per 1024-sample AAC frame,
// ~10 KB a minute (61 KB at 6 minutes, 608 KB at 60), against 960 KB a minute
// of 128 kbps audio. A 32nd of the file then holds the index of any AAC at
// 43 kbps or more. In an AIFF, a WAV, a W64, or a CAF it is any chunk after
// the audio, most often a tag with its cover (235 KB on a measured AIFF).
// dr_wav's open of a WAV or W64 stops at the data chunk, as dr_mp3's of MP3
// in a WAV does. Any other file dr_wav refuses goes to CoreAudio's parser,
// which walks to the end.
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

// A read-ahead's span until a play's handle sizes it, and the waveform's for
// good. A file with no duration keeps it too.
static const uint64_t kVibeReadAheadFloorBytes = 8 * 1024 * 1024;

// How far a play's read-ahead fetches past its reader: 30 s at the file's
// byte rate, its size over its duration. A fixed 8 MB lasts 3.5 minutes of a
// 320k MP3 but 7 s of a 24/192 WAV. Hi-res files on a NAS are the likeliest
// to stall. The span never falls below the floor. The cap bounds the memory
// of a play's two handles: the playing one and the parked prefetch.
static inline uint64_t VibeReadAheadSpanBytes(uint64_t size, double seconds) {
    static const double kAheadSeconds = 30, kCapBytes = 64.0 * 1024 * 1024;
    if (!(seconds > 0)) {
        return kVibeReadAheadFloorBytes;
    }
    double span = MIN((double)size / seconds * kAheadSeconds, kCapBytes);
    return MAX((uint64_t)span, kVibeReadAheadFloorBytes);
}

NS_ASSUME_NONNULL_END
