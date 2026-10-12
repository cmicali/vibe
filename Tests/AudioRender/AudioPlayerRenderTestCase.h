//
//  AudioPlayerRenderTestCase.h
//
//  The render suite's base class, AudioPlayerRenderTests. The file is named
//  for its role, and the class keeps its name. It holds no tests. Each topic
//  is a subclass in its own AudioPlayerRender<Topic>Tests.m beside it.
//

#import <XCTest/XCTest.h>
#import "AudioFixtures.h"
#import "AudioPlayer+Debug.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"
#import "AudioVoiceBusInternal.h"
#import "CloudFileMaterializer.h"
#include <float.h>
#include <stdatomic.h>

// Independent Apple AAC decodes can differ by a few float rounding bits.
// Lossless paths still require exact samples; AAC stays below -126 dBFS.
static const float kVibeAACDecodeTolerance = 4 * FLT_EPSILON;

// A stream's first fetch: running until the test completes or fails it, or
// the coordinator cancels it.
typedef NS_ENUM(int, VibeStreamOutcome) { VibeStreamRunning, VibeStreamCompleted, VibeStreamFailed, VibeStreamCancelled };

// The oracle and the measures, in AudioPlayerRenderTestCase.m.
NSMutableData *VibePCM(AVAudioPCMBuffer *buffer);
NSDictionary *VibeComparePCM(NSData *reference, NSData *capture, NSUInteger channels,
                         NSUInteger skip, float tolerance);
NSDictionary *VibeCompareWidePCM(NSData *wide, NSData *capture, NSUInteger channels,
                             NSUInteger aligned, NSUInteger skip);
NSData *VibeFloat32PCM(NSData *wide);
double VibeRMS(NSData *data, NSUInteger channels, NSUInteger channel, NSRange frames);
double VibeToneAmplitude(NSData *data, NSUInteger channels, NSUInteger channel, double rate, double frequency, NSRange frames);

// Sources more than one topic writes.
NSData *VibeStereoTone(NSUInteger frames, double rate, double frequency, float amplitude);
AudioTrack *VibeCueRow(NSURL *url, NSUInteger start, NSUInteger end);
NSData *VibeUniqueNoise(NSUInteger frames, uint32_t seed);
NSData *VibeAudibleFrames(NSData *pcm, NSUInteger channels);

// The shared fixture: capture, comparisons, the delegate trace and setup.
// It holds no tests, so it runs none. Each subclass is one topic in its own
// file, and the runner spreads the subclasses across its processes.
@interface AudioPlayerRenderTests : XCTestCase <AudioPlayerDelegate> {
    AudioPlayer *_player;
    NSMutableArray<NSDictionary *> *_events;
    NSError *_playError;
    NSURL *_temporary;
    double _rate;
    NSUInteger _channels;
    NSUInteger _blockSize;
    NSMutableData *_capture;
    NSArray<AudioTrack *> *_chain;
    NSUInteger _nextPrefetch;
    void (^_outputModesProvider)(NSString *, BOOL *, BOOL *);
    BOOL _priorAppleMPEGDecoder; // a test's choice is undone at tearDown
    // The remote file streamingCopyOf: stands up: its bytes, its first
    // fetch's part file and availability, and that fetch's fate.
    NSData *_streamBytes;
    NSURL *_streamURL;
    CloudFileAvailability *_stream;
    dispatch_semaphore_t _streamVerdict;
    _Atomic int _streamOutcome;
    _Atomic NSUInteger _streamFetches, _streamCancels;
    NSError *_streamFailure;
}
- (NSURL *)fixture:(NSString *)name;
- (NSURL *)optionalFixture:(NSString *)name;
- (AudioFileHandle *)open:(NSURL *)url decoder:(NSString *)decoder;
- (AVAudioPCMBuffer *)read:(NSURL *)url;
- (NSURL *)write:(NSData *)data rate:(double)rate channels:(NSUInteger)channels name:(NSString *)name;
- (NSURL *)writeBuffer:(AVAudioPCMBuffer *)buffer name:(NSString *)name;
- (NSURL *)writeBytes:(NSData *)bytes name:(NSString *)name;
- (NSData *)wideSourcePCM:(NSURL *)url;
- (NSData *)sourcePCM:(NSURL *)url;
- (NSUInteger)count:(NSString *)event;
- (void)settleUntil:(BOOL (^)(void))condition;
- (NSDictionary *)settledSignalSnapshot;
- (void)startPlayerAt:(double)rate channels:(NSUInteger)channels fx:(BOOL)fx bitPerfect:(BOOL)bitPerfect automatic:(BOOL)automatic;
- (AudioTrack *)play:(NSURL *)url paused:(BOOL)paused position:(double)position;
- (void)render:(NSUInteger)frames;
- (NSData *)renderSeconds:(double)seconds;
- (NSUInteger)startupSkip;
- (void)assertReference:(NSData *)reference capture:(NSData *)capture skip:(NSUInteger)skip tolerance:(float)tolerance;
- (void)assertFinite:(NSData *)data peak:(float)peak;
- (NSUInteger)assertExactExcerptsOf:(NSArray<NSData *> *)references inCapture:(NSData *)capture
                         rampFrames:(NSUInteger)rampFrames ramped:(NSUInteger *)ramped;
- (void)playOnTheDecodePool:(void (^)(void))play;
- (void)playOnTheDecodePoolBitPerfect:(BOOL)bitPerfect play:(void (^)(void))play;
- (NSURL *)streamingCopyOf:(NSURL *)source prefix:(NSUInteger)prefix name:(NSString *)name;
- (void)streamTo:(NSUInteger)end;
- (void)installTailWindow;
- (BOOL)finishStream:(VibeStreamOutcome)outcome;
- (VibeVoiceSnapshot)currentVoiceSnapshot;
- (BOOL)renderUntil:(BOOL (^)(void))condition;
- (void)shortenTheOpenDeadline;
- (NSTimeInterval)stallTheStream;
- (void)assertTheReplayOf:(NSData *)reference startsAt:(NSTimeInterval)held;
@end
