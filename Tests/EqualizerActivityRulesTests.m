//
//  EqualizerActivityRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "EqualizerActivityRules.h"

@interface EqualizerActivityRulesTests : XCTestCase
@end

@implementation EqualizerActivityRulesTests

- (void)testOnlyTheCompleteActivityStateRuns {
    // Exercise every combination so adding or accidentally weakening one gate
    // cannot leave an untested path that spends CPU while inactive.
    for (NSUInteger mask = 0; mask < 32; mask++) {
        VibeEqualizerActivityState state = {
            .audioOutputActive = (mask & (1 << 0)) != 0,
            .presentationVisible = (mask & (1 << 1)) != 0,
            .attachedToWindow = (mask & (1 << 2)) != 0,
            .hasLevelSource = (mask & (1 << 3)) != 0,
            .hasRenderableArea = (mask & (1 << 4)) != 0,
        };
        XCTAssertEqual(VibeEqualizerShouldRun(state), mask == 31,
                       @"unexpected activity decision for input mask %lu",
                       (unsigned long)mask);
    }
}

- (void)testOnlyAudioLossWithVisiblePixelsAnimatesReleaseToDots {
    for (NSUInteger mask = 0; mask < 32; mask++) {
        VibeEqualizerActivityState state = {
            .audioOutputActive = (mask & (1 << 0)) != 0,
            .presentationVisible = (mask & (1 << 1)) != 0,
            .attachedToWindow = (mask & (1 << 2)) != 0,
            .hasLevelSource = (mask & (1 << 3)) != 0,
            .hasRenderableArea = (mask & (1 << 4)) != 0,
        };
        XCTAssertEqual(VibeEqualizerCanAnimateReleaseToDots(state), mask == 30,
                       @"unexpected release decision for input mask %lu",
                       (unsigned long)mask);
    }
}

@end
