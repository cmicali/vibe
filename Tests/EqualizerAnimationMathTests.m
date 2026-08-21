//
//  EqualizerAnimationMathTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "EqualizerAnimationMath.h"

@interface EqualizerAnimationMathTests : XCTestCase
@end

@implementation EqualizerAnimationMathTests

- (void)testAttackIsShorterThanRelease {
    XCTAssertLessThan(kEqualizerAttackAnimationSeconds,
                      kEqualizerReleaseAnimationSeconds);
}

- (void)testConfiguredResponseDurations {
    XCTAssertEqualWithAccuracy(kEqualizerAttackAnimationSeconds, 3.0 * 0.045, 0.0001);
    XCTAssertEqualWithAccuracy(kEqualizerReleaseAnimationSeconds, 0.55, 0.0001);
}

- (void)testVisibleDirectionSelectsAnimationDuration {
    XCTAssertEqual(VibeEqualizerAnimationDuration(0.2, 0.8),
                   kEqualizerAttackAnimationSeconds);
    XCTAssertEqual(VibeEqualizerAnimationDuration(0.8, 0.2),
                   kEqualizerReleaseAnimationSeconds);
    XCTAssertEqual(VibeEqualizerAnimationDuration(0.5, 0.5),
                   kEqualizerReleaseAnimationSeconds);
}

- (void)testOnlyMaterialTargetChangesRetarget {
    XCTAssertFalse(VibeEqualizerTargetMateriallyChanged(
            0.4f, 0.4f + kEqualizerMaterialTargetDelta * 0.5f));
    XCTAssertTrue(VibeEqualizerTargetMateriallyChanged(
            0.4f, 0.4f + kEqualizerMaterialTargetDelta * 1.01f));
    XCTAssertTrue(VibeEqualizerTargetMateriallyChanged(0.4f, 0.7f));
}

- (void)testSubthresholdChangesAccumulateAgainstTheLastAppliedTarget {
    float applied = 0.4f;
    float first = applied + kEqualizerMaterialTargetDelta * 0.75f;
    XCTAssertFalse(VibeEqualizerTargetMateriallyChanged(applied, first));
    float second = applied + kEqualizerMaterialTargetDelta * 1.5f;
    XCTAssertTrue(VibeEqualizerTargetMateriallyChanged(applied, second));
}

- (void)testInvalidAndOutOfRangeLevelsAreSafe {
    XCTAssertEqual(VibeEqualizerClampedLevel(NAN), 0.0f);
    XCTAssertEqual(VibeEqualizerClampedLevel(INFINITY), 0.0f);
    XCTAssertEqual(VibeEqualizerClampedLevel(-1.0f), 0.0f);
    XCTAssertEqual(VibeEqualizerClampedLevel(2.0f), 1.0f);
}

- (void)testInvalidVisibleScaleFailsClosedToReleaseTiming {
    XCTAssertEqual(VibeEqualizerAnimationDuration(NAN, 0.5),
                   kEqualizerReleaseAnimationSeconds);
    XCTAssertEqual(VibeEqualizerAnimationDuration(0.5, INFINITY),
                   kEqualizerReleaseAnimationSeconds);
}

@end
