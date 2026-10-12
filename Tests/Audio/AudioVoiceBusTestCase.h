//
//  AudioVoiceBusTestCase.h
//
//  The harness the voice bus tests share: float WAV fixtures in a per-test
//  temp directory, a bus whose output buffers the test owns, and the render,
//  fill and drain the pump would run around a slice. It runs no tests.
//  AudioVoiceBusTests and AudioVoiceBusPoolTests subclass it.
//
//  The same drain that reports a voice ended recycles its slot, so the harness
//  reads the snapshot inside that handler, as the player must.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import "AudioVoiceBusInternal.h"
#import "AudioPlayer+Debug.h"
#import "AudioFixtures.h"
#import <objc/runtime.h>
#include <stdatomic.h>

static const double kRate = 48000;

@interface AudioVoiceBusTestCase : XCTestCase {
@protected
    NSURL *_temporary;
    AudioVoiceBus *_bus;
    dispatch_queue_t _queue;
    AudioBufferList *_output;
    float *_outputData[8];
    double _sampleTime;
    NSMutableArray<NSDictionary *> *_events;
    NSMutableDictionary<NSNumber *, NSValue *> *_endedSnapshots;
    NSMutableDictionary<NSNumber *, NSError *> *_endedErrors;
}
// Interleaved float PCM at `rate`/`channels`, written as a float WAV.
- (NSURL *)writePCM:(NSData *)interleaved rate:(double)rate channels:(NSUInteger)channels name:(NSString *)name;
- (NSURL *)writeBuffer:(AVAudioPCMBuffer *)buffer name:(NSString *)name;
- (NSData *)noiseFrames:(NSUInteger)frames channels:(NSUInteger)channels seed:(uint32_t)seed;
- (NSData *)constant:(float)value frames:(NSUInteger)frames channels:(NSUInteger)channels;
- (AudioFileHandle *)open:(NSURL *)url;
- (void)makeBusAtRate:(double)rate channels:(NSUInteger)channels;
// With a real decode queue, for the race tests: the fills are the bus's own.
- (void)makeBusAtRate:(double)rate channels:(NSUInteger)channels inlineDecoding:(BOOL)inlineDecoding;
- (void)makeBusWithFormat:(AVAudioFormat *)format inlineDecoding:(BOOL)inlineDecoding;
- (void)releaseOutput;
- (VibeVoiceRamp)unity;
- (VibeVoiceID)startFile:(AudioFileHandle *)file gain:(float)gain ramp:(VibeVoiceRamp)ramp paused:(BOOL)paused;
// One render of `frames`, appended to `capture` interleaved, with the fill
// before and the drain after, exactly as the pump does around a slice.
- (BOOL)render:(uint32_t)frames into:(NSMutableData *)capture;
- (BOOL)renderWithoutFilling:(uint32_t)frames into:(NSMutableData *)capture;
- (void)drain;
- (BOOL)hasEnded:(VibeVoiceID)voice;
- (VibeVoiceSnapshot)endedSnapshot:(VibeVoiceID)voice;
- (NSData *)renderUntilEnded:(VibeVoiceID)voice blockSize:(uint32_t)block limit:(NSUInteger)limit;
- (NSArray<NSNumber *> *)eventsForVoice:(VibeVoiceID)voice;
- (void)assertCapture:(NSData *)capture equalsSource:(NSData *)source;
- (NSUInteger)firstDifference:(NSData *)a from:(NSData *)b;
- (void)assertSilent:(NSData *)capture from:(NSUInteger)sample;
@end
