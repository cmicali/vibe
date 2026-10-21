//
//  NetworkReadAheadMath.h
//  Vibe
//
//  How far a read-ahead fetches past its reader (NetworkReadAhead.m).
//

#import <Foundation/Foundation.h>

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
