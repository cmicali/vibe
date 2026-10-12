//
//  MaterializationTestFakes.h
//
//  The fakes AudioFileMaterializationCoordinatorTests builds its coordinator
//  over. VibeTestDatalessProbeController answers the dataless probe, and a
//  test can gate each call. VibeTestMaterializationController hands out
//  provider operations that a test completes or cancels by hand.
//

#import <Foundation/Foundation.h>

#import "AudioFileMaterializationCoordinatorInternal.h"

@class VibeTestMaterializationController;

@interface VibeTestDatalessProbeController : NSObject
- (BOOL)probeURL:(NSURL *)url;
- (void)setResults:(NSArray<NSNumber *> *)results forName:(NSString *)name;
- (void)gateCall:(NSUInteger)call forName:(NSString *)name;
- (void)releaseCall:(NSUInteger)call forName:(NSString *)name;
- (void)releaseAll;
- (BOOL)waitForCallCount:(NSUInteger)count forName:(NSString *)name;
- (BOOL)waitForIdle;
- (NSUInteger)callCountForName:(NSString *)name;
- (NSUInteger)totalCallCount;
- (NSUInteger)inFlightCount;
- (NSArray<NSString *> *)timedOutGates;
@end

// TRAP: if the probe regresses to running on the caller, a gate blocks the
// test method itself and tearDown never releases it. The deadline turns that
// hang into a reported failure.
static const NSTimeInterval kProbeGateTimeout = VIBE_TEST_GATE_TIMEOUT;

@interface VibeTestMaterializationOperation : NSObject <AudioFileMaterializationOperation>
- (instancetype)initWithURL:(NSURL *)url
                       role:(VibeAudioFileMaterializationRole)role
                 controller:(VibeTestMaterializationController *)controller;
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) VibeAudioFileMaterializationRole role;
@property (nonatomic, readonly) BOOL started;
@property (nonatomic, readonly) NSUInteger cancellationCount;
- (void)deferCancellationCompletion;
- (void)completeReady:(BOOL)ready;
- (void)completeWithError:(NSError *)error;
@end

@interface VibeTestMaterializationController : NSObject
- (id<AudioFileMaterializationOperation>)operationForURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role;
- (void)operationDidStart:(VibeTestMaterializationOperation *)operation;
- (BOOL)waitForStartedCount:(NSUInteger)count;
- (NSArray<VibeTestMaterializationOperation *> *)startedOperations;
- (VibeTestMaterializationOperation *)operationForLastPathComponent:(NSString *)name;
- (NSUInteger)totalCancellationCount;
- (void)completeAll;
@end
