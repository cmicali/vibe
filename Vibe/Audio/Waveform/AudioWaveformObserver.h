//
//  AudioWaveformObserver.h
//  Vibe
//
//  What rides a waveform decode beside the summary. The app attaches
//  observers to its requests (VibeWaveformAnalysis.observers), and the loader
//  knows nothing of what they compute.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One decode's share of an observer. It takes the decode's mono blocks in
// stream order, then gives its result once.
@protocol AudioWaveformSink <NSObject>

// Mono float32, from AudioWaveformMonoMix. Any frame count per call.
- (void)appendMonoSamples:(const float *)samples frameCount:(NSUInteger)frameCount;

// Asked once, after the last block, and only of a complete decode. The cache
// files it beside the summary under the observer's identifier.
- (NSNumber *)waveformResult;

@end

typedef id<AudioWaveformSink> _Nonnull (^AudioWaveformSinkFactory)(double sampleRate, NSRange window);

@interface AudioWaveformObserver : NSObject

// The identifier names the result in the archive, so it never changes. The
// block makes one sink per decode, given the file's rate and the window's
// frames.
- (instancetype)initWithIdentifier:(NSString *)identifier
                       sinkFactory:(AudioWaveformSinkFactory)sinkFactory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *identifier;

- (id<AudioWaveformSink>)sinkForSampleRate:(double)sampleRate window:(NSRange)window;

// Every identifier an observer was made with in this process. Format 6 of the
// archive lists no identifiers, so an entry reads the results of these.
+ (NSSet<NSString *> *)identifiers;

@end

NS_ASSUME_NONNULL_END
