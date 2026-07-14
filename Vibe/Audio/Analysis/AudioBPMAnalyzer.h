//
//  AudioBPMAnalyzer.h
//  Vibe
//
//  Streaming tempo estimator fed by the waveform loader's decode pass, so BPM
//  detection never costs a second full-file read. Feed interleaved float32
//  buffers in file order, then call finish once at end of file.
//
//  Method: a spectral-flux onset-strength envelope (vDSP FFT, 1024-sample
//  frames, 256 hop) accumulated during streaming; finish() detrends the
//  envelope, autocorrelates it over the 60-200 BPM lag range, scores each
//  candidate with a harmonic comb (lag + 2x + 3x, suppressing half/double
//  tempo errors), applies a mild prior centered near 120 BPM, and refines the
//  winning lag by parabolic interpolation. Returns 0 when the track is too
//  short or the tempo peak is not prominent enough to trust (ambient,
//  rubato, speech).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioBPMAnalyzer : NSObject

- (instancetype)initWithSampleRate:(double)sampleRate channelCount:(NSUInteger)channelCount;

// Interleaved float32 (L0 R0 L1 R1 ...), any frame count per call.
- (void)appendSamples:(const float *)samples frameCount:(NSUInteger)frameCount;

// Estimated tempo in BPM, or 0 if undetectable. Call once, after all samples.
- (float)finish;

@end

NS_ASSUME_NONNULL_END
