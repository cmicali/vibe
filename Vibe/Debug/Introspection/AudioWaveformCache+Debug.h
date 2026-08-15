//
//  AudioWaveformCache+Debug.h
//  Vibe
//
//  Declaration-only, and deliberately so: the implementation stays in the
//  class's own .m, and ObjC's dynamic dispatch needs no more than this to call
//  it. Re-declaring here is what keeps the shipping header free of #if DEBUG.
//

#if DEBUG

#import "AudioWaveformCache.h"

@interface AudioWaveformCache (Debug)

// Pre-warm: decodes and persists a file's waveform, and its detected BPM and
// key, without cancelling or delivering to the current load, so the running UI
// is untouched. It runs the same lookup-or-decode path as a normal load, but a
// fresh decode's completion waits for the disk write, so the entry is durably
// cached once it fires. The completion fires on the main thread: ok is NO on a
// decode failure, wasCached is YES when the entry already existed and no decode
// ran, bpm is 0 and key is -1 when none was detected.
- (void)cacheWaveformForURL:(NSURL *)url
                 completion:(void (^)(BOOL ok, BOOL wasCached, float bpm, NSInteger key))completion;

// Removes a single file's waveform cache entry. The cache key derives from the
// file's current size and mtime, so the file must still exist unchanged to
// resolve the same entry. The completion fires on the main thread with whether
// an entry was present.
- (void)clearCachedWaveformForURL:(NSURL *)url
                       completion:(void (^)(BOOL wasPresent))completion;

@end

#endif
