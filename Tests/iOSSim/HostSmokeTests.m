// The harness itself: the host runs, and its settings are the guard's.

#import "IOSSimTestCase.h"
#import "AppSettingsInternal.h"
#import "TestFilesystemGuard.h"

@interface HostSmokeTests : IOSSimTestCase
@end

@implementation HostSmokeTests

- (void)testTheHostRunsWithAWindowScene {
    XCTAssertNotNil(UIApplication.sharedApplication);
    XCTAssertNotNil(self.window.windowScene);
}

// TRAP: the guard must be in before the app registers its defaults, or the
// in-memory store reads every unset setting as zero.
- (void)testSettingsLiveInTheGuardsStoreWithTheirDefaultsRegistered {
    XCTAssertTrue([NSUserDefaults.standardUserDefaults isKindOfClass:VibeTestUserDefaults.class]);
    // Registered, never stored: an unregistered key would read nil here.
    for (NSString *key in @[SETTING_FOLDER_OPEN_SORT, SETTING_REPEAT_MODE, SETTING_AUDIO_FX_ENABLED,
                            SETTING_ANALYZE_BPM, SETTING_CROSSFADE_MILLISECONDS]) {
        XCTAssertNotNil([NSUserDefaults.standardUserDefaults objectForKey:key], @"%@", key);
    }
}

@end
