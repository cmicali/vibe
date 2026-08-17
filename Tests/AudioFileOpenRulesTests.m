//
// Standardized-path identity for bounded audio-open claims.
//

#import <XCTest/XCTest.h>

#import "AudioFileOpenRules.h"

@interface AudioFileOpenRulesTests : XCTestCase
@end

@implementation AudioFileOpenRulesTests

- (void)testEquivalentFilePathsShareOneClaimSpelling {
    NSURL *direct = [NSURL fileURLWithPath:@"/tmp/vibe/audio.flac"];
    NSURL *lexicalAlias = [NSURL fileURLWithPath:@"/tmp/vibe/part/../audio.flac"];
    XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(direct),
                          VibeStandardizedAudioOpenPath(lexicalAlias));
}

- (void)testNonFileURLUsesItsAbsoluteIdentity {
    NSURL *url = [NSURL URLWithString:@"https://example.com/audio.flac?take=2"];
    XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(url), url.absoluteString);
}

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
