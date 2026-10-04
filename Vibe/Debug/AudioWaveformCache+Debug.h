//
//  AudioWaveformCache+Debug.h
//  Vibe
//
//  Declaration-only, like AudioPlayer+Debug.h.
//

#if DEBUG

#import "AudioWaveformCache.h"

@interface AudioWaveformCache (Debug)

// Decodes and persists a file's waveform, BPM and key through the normal
// lookup-or-decode path, without cancelling or delivering to the current load.
// A fresh decode completes only after the disk write. Main-thread completion:
// ok is NO on failure, wasCached means no decode ran, bpm 0 and key -1 mean
// none detected.
- (void)cacheWaveformForURL:(NSURL *)url
                 completion:(void (^)(BOOL ok, BOOL wasCached, float bpm, NSInteger key))completion;

// Removes one file's entry. The key derives from the file's current size and
// mtime, so the file must still exist unchanged. Main-thread completion.
- (void)clearCachedWaveformForURL:(NSURL *)url
                       completion:(void (^)(BOOL wasPresent))completion;

// Paces every decode that starts after it is set so the whole pass takes about
// this long, its reads held back as a long file's or a slow disk's are; 0, the
// default, is full speed. The deliveries are the loader's own, so the views'
// progressive fill-in can be watched on any file. A cached waveform never
// decodes: clear its entry first. Any thread.
@property (class, nonatomic) NSTimeInterval debugDecodeSeconds;

@end

#endif
