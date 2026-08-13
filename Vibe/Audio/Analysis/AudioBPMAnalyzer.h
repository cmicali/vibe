//
//  AudioBPMAnalyzer.h
//  Vibe
//
//  A streaming tempo estimator fed by the waveform loader's decode pass, so
//  that BPM detection never costs a second full-file read. Feed it mono
//  float32 buffers in file order — the loader downmixes each decode buffer
//  once and shares it with the waveform chunker — then call finish once at end
//  of file.
//
//  The method: a spectral-flux onset-strength envelope, built with a vDSP FFT
//  over 1024-sample frames at a 256 hop, accumulates during streaming. finish()
//  then detrends the envelope, autocorrelates it over the 60-200 BPM lag
//  range, scores each candidate with a harmonic comb at the lag and twice and
//  three times it, which suppresses half- and double-tempo errors, rescores
//  the candidate family with a time-domain phase comb, and sharpens the
//  winner's fractional period with a tolerance-free interpolated fine pass,
//  landing within about ±0.01 BPM on a steady tempo. It returns 0 when the
//  track is too short, or when the tempo peak is not prominent enough to
//  trust, as with ambient music, rubato or speech.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioBPMAnalyzer : NSObject

- (instancetype)initWithSampleRate:(double)sampleRate;

// Mono float32; see AudioWaveformMonoMix. Any frame count per call.
- (void)appendMonoSamples:(const float *)samples frameCount:(NSUInteger)frameCount;

// The estimated tempo in BPM, or 0 if undetectable. Call it once, after every
// sample has been fed in.
- (float)finish;

@end

NS_ASSUME_NONNULL_END
