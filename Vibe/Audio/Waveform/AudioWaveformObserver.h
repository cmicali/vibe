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
// files it beside the summary under the observer's identifier. It must be a
// property-list object: an NSNumber, NSString, NSDate or NSData, or an
// NSArray or NSDictionary (string keys) of those. Anything else is a
// programming error, which asserts in Debug and is dropped in Release.
- (id)waveformResult;

@end

typedef id<AudioWaveformSink> _Nonnull (^AudioWaveformSinkFactory)(double sampleRate, NSRange window);

@interface AudioWaveformObserver : NSObject

// The identifier names the result in the archive. An app versions an
// observer by changing its identifier, so a changed algorithm leaves old
// results uncovered and nothing else needs a bump. The block makes one sink
// per decode, given the file's rate and the window's frames.
- (instancetype)initWithIdentifier:(NSString *)identifier
                       sinkFactory:(AudioWaveformSinkFactory)sinkFactory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *identifier;

- (id<AudioWaveformSink>)sinkForSampleRate:(double)sampleRate window:(NSRange)window;

@end

NS_ASSUME_NONNULL_END
