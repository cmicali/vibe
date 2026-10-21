#import <XCTest/XCTest.h>

#import "AudioFileOpenDeliveryRules.h"

@interface AudioFileOpenDeliveryRulesTests : XCTestCase
@end

@implementation AudioFileOpenDeliveryRulesTests

- (void)testDetachWinsBeforeQueuedDeliveryBegins {
    VibeAudioFileOpenDeliveryState state = VibeAudioFileOpenDeliveryWaiting;
    XCTAssertTrue(VibeAudioFileOpenDetachDelivery(&state));
    XCTAssertFalse(VibeAudioFileOpenBeginDelivery(&state));
    XCTAssertEqual(state, VibeAudioFileOpenDeliveryDetached);
}

- (void)testDeliveryAlreadyRunningCannotBeRetracted {
    VibeAudioFileOpenDeliveryState state = VibeAudioFileOpenDeliveryWaiting;
    XCTAssertTrue(VibeAudioFileOpenBeginDelivery(&state));
    XCTAssertFalse(VibeAudioFileOpenDetachDelivery(&state));
    XCTAssertEqual(state, VibeAudioFileOpenDeliveryRunning);
}

@end
