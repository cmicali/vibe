//
//  AudioFileMaterializationCoordinatorTestCase.h
//  VibeTests
//
//  The harness the stage-1 coordinator tests share: a real coordinator over
//  the fakes in MaterializationTestFakes, a clock the test sets, and a
//  teardown that waits for the coordinator's accounting to settle. It runs no
//  tests. Each topic is a subclass in its own file beside it.
//

#import <XCTest/XCTest.h>

#import "AudioFileMaterializationCoordinator+Debug.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "MaterializationTestFakes.h"

@interface AudioFileMaterializationCoordinatorTestCase : XCTestCase {
@protected
    VibeTestMaterializationController *_controller;
    VibeTestDatalessProbeController *_probeController;
    AudioFileMaterializationCoordinator *_coordinator;
    dispatch_queue_t _completionQueue;
    NSTimeInterval _now;
}
- (NSURL *)URLNamed:(NSString *)name;
- (AudioLoadingConfiguration *)configurationWithValues:(VibeAudioLoadingConfigurationValues)values;
- (void)makeCoordinatorWithValues:(VibeAudioLoadingConfigurationValues)values;
- (BOOL)waitForCondition:(BOOL (^)(void))condition;
- (void)drainMainQueue;
- (AudioFileMaterializationRequestToken *)requestName:(NSString *)name
                                                  role:(VibeAudioFileMaterializationRole)role
                                            completion:(VibeAudioFileMaterializationCompletion)completion;
@end
