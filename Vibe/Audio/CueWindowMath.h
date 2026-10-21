//
//  CueWindowMath.h
//  Vibe
//

#import <Foundation/Foundation.h>

// CD frames, the unit of a cue window.
static const NSUInteger kVibeCDFramesPerSecond = 75;

// Where a window's cue end lands in a file's frames: rounded at the file's
// rate, unclamped, or 0 for a window running to the file's end. Never derived
// from the length, which may be an estimate (a streaming MP3's): an end past
// where the stream really ends stops there anyway.
static inline int64_t VibeCueEndFrame(NSUInteger cueEnd, double sampleRate) {
    return cueEnd > 0 ? llround((double)cueEnd * sampleRate / kVibeCDFramesPerSecond) : 0;
}

// A track's window in file frames, from its cue window in CD frames (1/75 s):
// rounded at the file's rate, the two rows meeting at a marker round the same
// point, so they stay contiguous at a rate 75 does not divide. A cue end of 0,
// or one past the file's, is the file's end; empty when nothing is left.
// Against a length that is only an estimate (AudioFileHandle
// lengthIsEstimated) nothing is refused or cut short: the cue end stands, and
// a window to the file's end reaches a frame past its start at least; both
// clamp once the length settles.
static inline NSRange VibeCueWindow(NSUInteger cueStart, NSUInteger cueEnd, double sampleRate, int64_t fileLength,
                                    BOOL lengthIsEstimated) {
    int64_t start = llround((double)cueStart * sampleRate / kVibeCDFramesPerSecond);
    int64_t cue = VibeCueEndFrame(cueEnd, sampleRate);
    if (lengthIsEstimated) {
        fileLength = MAX(fileLength, cueEnd > 0 ? cue : start + 1);
    }
    int64_t end = cueEnd > 0 ? MIN(cue, fileLength) : fileLength;
    return start < end ? NSMakeRange((NSUInteger)start, (NSUInteger)(end - start)) : NSMakeRange(0, 0);
}
