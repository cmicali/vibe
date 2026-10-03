//
//  AudioWaveformCache+Debug.h
//  Vibe
//
//  Declaration-only, like AudioPlayer+Debug.h.
//

#if DEBUG

#import "AudioWaveformCache.h"

@class CodableAudioWaveform;

@interface AudioWaveformCache (Debug)

// How far a waveform has filled: past its last chunk holding any audio, as a
// fraction of its chunks. A streaming decode fills from the start, so this
// is how far the download let it read; silence reads as unfilled.
+ (double)debugFilledFractionOfWaveform:(CodableAudioWaveform *)waveform;

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

@end

#endif
