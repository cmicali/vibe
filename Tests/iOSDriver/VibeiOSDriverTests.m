//
//  VibeiOSDriverTests.m
//  Vibe (iOS)
//
//  Not a test suite: an interactive touch driver in XCUITest clothing (the
//  WebDriverAgent pattern). Touch synthesis exists only inside the XCUITest
//  harness; there is no public UITouch constructor. The one "test" polls
//  VIBE_DRIVER_DIR (build/ios-driver/<UDID>, passed by drive-ios.sh as
//  TEST_RUNNER_VIBE_DRIVER_DIR) for vibe-touch-*.json in the debug channel's
//  {id, args} format and replies to vibe-touch-response-<id>.txt.
//
//  Coordinates are app-window POINTS, top-left origin: device pixels from
//  `simctl io <UDID> screenshot` (the session's simulator, sim-udid.sh)
//  divided by the screen scale.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>

static NSString *const kAppBundleID = @"com.commonwealthrecordings.Vibe";
static NSString *const kReadyMarker = @"vibe-driver-ready";
// The loop's absolute lifetime; drive-ios.sh stop (the quit verb) is the
// normal exit.
static const NSTimeInterval kMaxSessionSeconds = 4 * 60 * 60;

@interface VibeiOSDriverTests : XCTestCase
@end

@implementation VibeiOSDriverTests {
    XCUIApplication *_app;
    XCUIApplication *_player;
    BOOL             _attached;
    NSString        *_dir;
}

- (void)setUp {
    // A bad command must reply {"error"} and keep serving, never abort the
    // session.
    self.continueAfterFailure = YES;
}

static NSString *JSONString(NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingSortedKeys
                                                     error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                : @"{\"error\": \"response not JSON-serializable\"}";
}

static BOOL ParseDouble(NSString *token, double *out) {
    NSScanner *scanner = [NSScanner scannerWithString:token];
    return [scanner scanDouble:out] && scanner.isAtEnd;
}

// XCTest waits for the target to quiesce before AND after every synthesized
// event, and a PLAYING app never idles (its display link): 60s timeout each
// side, ~2 minutes per gesture. This reaches XCTest internals, as
// WebDriverAgent and Appium do, so it is defensive — a renamed method only
// makes gestures slow. Test-harness-only: it never ships in an app binary.
static void ForceYesMethod(Class cls, NSString *name) {
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(name)) : NULL;
    if (method) {
        method_setImplementation(method, imp_implementationWithBlock(^BOOL(id target) {
            return YES;
        }));
    }
}

static void NoOpMethod(Class cls, NSString *name) {
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(name)) : NULL;
    if (method) {
        // Extra arguments are simply never read by the no-op.
        method_setImplementation(method, imp_implementationWithBlock(^(id target) {}));
    }
}

static void DisableQuiescenceWaits(void) {
    Class process = NSClassFromString(@"XCUIApplicationProcess");
    Class application = NSClassFromString(@"XCUIApplication");
    // The getters this Xcode's XCUIAutomation consults per event; forcing
    // both skips the waits wholesale.
    ForceYesMethod(process, @"shouldSkipPreEventQuiescence");
    ForceYesMethod(process, @"shouldSkipPostEventQuiescence");
    // Belt and braces for the names other Xcode versions used.
    NoOpMethod(application, @"_waitForQuiescence");
    NoOpMethod(application, @"_waitForQuiescenceAsPreEvent:");
    NoOpMethod(process, @"waitForQuiescenceIncludingAnimationsIdle:");
    NoOpMethod(process, @"waitForQuiescenceIncludingAnimationsIdle:isPreEvent:");
}

- (XCUICoordinate *)coordinateAtX:(double)x y:(double)y {
    return [[_app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
            coordinateWithOffset:CGVectorMake(x, y)];
}

// Foregrounds the app if something else is, relaunching a dead one with the
// same audio-silencing argv launch-ios.sh uses, so a self-heal never plays
// through the mac's speakers.
// TRAP: XCTest snapshots only a process it launched or activated. Against
// the one launch-ios.sh started, every query retries for 60 s and then
// RELAUNCHES the app itself — playlist gone, and without the silencing
// flags. So the player is activated, which attaches without a relaunch, on
// the first gesture and after every relaunch (`attach`, which launch-ios.sh
// sends).
- (void)ensureForeground {
    XCUIApplicationState state = _app.state;
    if (state == XCUIApplicationStateNotRunning) {
        _app.launchArguments = @[@"--no-audio-hw", @"--silent"];
        [_app launch];
    }
    else if (state != XCUIApplicationStateRunningForeground || (_app == _player && !_attached)) {
        [_app activate];
    }
    if (_app == _player) {
        _attached = YES;
    }
}

// Returns the reply. tokens[0] is the verb; *quit is set by the quit verb.
- (NSString *)performCommand:(NSArray<NSString *> *)tokens quit:(BOOL *)quit {
    NSString *verb = tokens.firstObject ?: @"";
    double a1 = 0, a2 = 0, a3 = 0, a4 = 0;

    if ([verb isEqualToString:@"springboard"]) {
        if (tokens.count < 2 || ![@[@"tap", @"press", @"drag", @"type", @"tap_label", @"tree"] containsObject:tokens[1]]) {
            return JSONString(@{@"error": @"springboard needs: tap|press|drag|type|tap_label|tree and arguments"});
        }
        XCUIApplication *player = _app;
        _app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
        @try {
            return [self performCommand:[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)] quit:quit];
        }
        @finally {
            _app = player;
        }
    }

    if ([verb isEqualToString:@"attach"]) {
        _attached = NO;
        [self ensureForeground];
        return JSONString(@{@"ok": @YES});
    }
    if (_app == _player && ([verb isEqualToString:@"tree"] || [verb isEqualToString:@"tap_label"]
                            || [verb isEqualToString:@"type"])) {
        [self ensureForeground];
    }
    if ([verb isEqualToString:@"tree"]) {
        return JSONString(@{@"tree": _app.debugDescription});
    }
    if ([verb isEqualToString:@"tap_label"]) {
        if (tokens.count != 2) return JSONString(@{@"error": @"tap_label needs: label"});
        XCUIElement *element = [[_app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:tokens[1]].firstMatch;
        if (!element.exists) return JSONString(@{@"error": @"label not found"});
        [element tap];
        return JSONString(@{@"ok": @YES});
    }
    if ([verb isEqualToString:@"quit"]) {
        *quit = YES;
        return JSONString(@{@"ok": @YES, @"quit": @YES});
    }
    if ([verb isEqualToString:@"home"]) {
        [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
        return JSONString(@{@"ok": @YES});
    }
    // TRAP: the keyboard lives in its own UIRemoteKeyboardWindow, so a
    // coordinate tap on a key lands on the app behind it and looks like the
    // key did nothing. Type through typeText:, which uses the responder chain.
    if ([verb isEqualToString:@"type"]) {
        if (tokens.count < 2) {
            return JSONString(@{@"error": @"type needs: <text>"});
        }
        // Rejoined, so a query with spaces survives the tokenizer.
        NSString *text = [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]
                componentsJoinedByString:@" "];
        [_app typeText:text];
        return JSONString(@{@"ok": @YES, @"typed": text});
    }
    if ([verb isEqualToString:@"rotate"]) {
        // Named by the DEVICE's physical rotation, like the Simulator menu:
        // "left" turns the device counterclockwise (home side on the right).
        NSDictionary *orientations = @{
            @"portrait": @(UIDeviceOrientationPortrait),
            @"left": @(UIDeviceOrientationLandscapeLeft),
            @"right": @(UIDeviceOrientationLandscapeRight),
        };
        NSNumber *orientation = tokens.count == 2 ? orientations[tokens[1]] : nil;
        if (!orientation) {
            return JSONString(@{@"error": @"rotate needs: portrait|left|right"});
        }
        [self ensureForeground];
        XCUIDevice.sharedDevice.orientation = (UIDeviceOrientation)orientation.integerValue;
        return JSONString(@{@"ok": @YES, @"orientation": tokens[1]});
    }
    if ([verb isEqualToString:@"tap"] || [verb isEqualToString:@"double_tap"]) {
        if (tokens.count != 3 || !ParseDouble(tokens[1], &a1) || !ParseDouble(tokens[2], &a2)) {
            return JSONString(@{@"error": [verb stringByAppendingString:@" needs: x y"]});
        }
        [self ensureForeground];
        XCUICoordinate *c = [self coordinateAtX:a1 y:a2];
        if ([verb isEqualToString:@"tap"]) {
            [c tap];
        }
        else {
            [c doubleTap];
        }
        return JSONString(@{@"ok": @YES, @"x": @(a1), @"y": @(a2)});
    }
    if ([verb isEqualToString:@"press"]) {
        if (tokens.count != 4 || !ParseDouble(tokens[1], &a1) || !ParseDouble(tokens[2], &a2)
                || !ParseDouble(tokens[3], &a3) || a3 <= 0) {
            return JSONString(@{@"error": @"press needs: x y seconds"});
        }
        [self ensureForeground];
        [[self coordinateAtX:a1 y:a2] pressForDuration:a3];
        return JSONString(@{@"ok": @YES});
    }
    if ([verb isEqualToString:@"drag"]) {
        double seconds = 0;
        BOOL haveDuration = tokens.count == 6 && ParseDouble(tokens[5], &seconds) && seconds > 0;
        if ((tokens.count != 5 && !haveDuration)
                || !ParseDouble(tokens[1], &a1) || !ParseDouble(tokens[2], &a2)
                || !ParseDouble(tokens[3], &a3) || !ParseDouble(tokens[4], &a4)) {
            return JSONString(@{@"error": @"drag needs: x1 y1 x2 y2 [seconds]"});
        }
        [self ensureForeground];
        XCUICoordinate *from = [self coordinateAtX:a1 y:a2];
        XCUICoordinate *to = [self coordinateAtX:a3 y:a4];
        if (haveDuration) {
            // Velocity in points/second reproduces the requested duration; the
            // waveform's 1:1 scrub needs a slow drag, not XCTest's default flick.
            double distance = hypot(a3 - a1, a4 - a2);
            [from pressForDuration:0.1
              thenDragToCoordinate:to
                      withVelocity:(XCUIGestureVelocity)MAX(distance / seconds, 1)
               thenHoldForDuration:0.1];
        }
        else {
            [from pressForDuration:0.05 thenDragToCoordinate:to];
        }
        return JSONString(@{@"ok": @YES});
    }
    // XCUITest synthesizes multi-touch only through an ELEMENT, so the waveform
    // carries an accessibilityIdentifier purely to be findable here
    // (kWaveformScrubberIdentifier, WaveformScrubberView.mm).
    //
    // Scale > 1 opens the fingers, which zooms IN (less of the track visible).
    // Velocity is scale-factors per second and must be negative to zoom out.
    if ([verb isEqualToString:@"pinch"]) {
        if (tokens.count != 3 || !ParseDouble(tokens[1], &a1) || !ParseDouble(tokens[2], &a2)
                || a1 <= 0) {
            return JSONString(@{@"error": @"pinch needs: scale velocity"});
        }
        [self ensureForeground];
        XCUIElement *waveform = _app.otherElements[@"waveform-scrubber"];
        // The card has one per page and only the current one is hittable; the
        // query is resolved rather than waited on, so a missing element is an
        // error rather than a 60s hang.
        if (!waveform.exists) {
            return JSONString(@{@"error": @"no waveform on screen — expand the player first"});
        }
        [waveform pinchWithScale:(CGFloat)a1 velocity:(XCUIGestureVelocity)a2];
        return JSONString(@{@"ok": @YES, @"scale": @(a1), @"velocity": @(a2)});
    }
    return JSONString(@{@"error": [NSString stringWithFormat:
            @"unknown command '%@'. Commands: tap <x> <y>, double_tap <x> <y>, "
            @"press <x> <y> <seconds>, drag <x1> <y1> <x2> <y2> [seconds], "
            @"pinch <scale> <velocity>, type <text>, tap_label <label>, tree, "
            @"rotate portrait|left|right, home, attach, springboard <gesture> [args], quit", verb]});
}

// Returns YES when the command asked the session to end.
- (BOOL)handleCommandFile:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    // The dictionary check must gate EVERY keyed read: a JSON array at the
    // top level would take objectForKeyedSubscript: outside the @try below
    // and abort the whole session.
    if (![payload isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSString *commandId = payload[@"id"];
    NSArray *args = payload[@"args"];
    if (![commandId isKindOfClass:NSString.class] || commandId.length == 0
            || ![args isKindOfClass:NSArray.class] || args.count == 0) {
        return NO;
    }
    BOOL quit = NO;
    NSString *reply;
    @try {
        reply = [self performCommand:args quit:&quit];
    }
    @catch (NSException *exception) {
        // An off-screen coordinate or a dead app proxy raises; the session
        // must survive it.
        reply = JSONString(@{@"error": exception.reason ?: exception.name});
    }
    NSString *responsePath = [_dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"vibe-touch-response-%@.txt", commandId]];
    [reply writeToFile:responsePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return quit;
}

- (void)testDriverLoop {
    _dir = NSProcessInfo.processInfo.environment[@"VIBE_DRIVER_DIR"];
    XCTAssertTrue(_dir.length > 0, @"VIBE_DRIVER_DIR not set — start via drive-ios.sh");
    if (_dir.length == 0) {
        return;
    }
    _app = [[XCUIApplication alloc] initWithBundleIdentifier:kAppBundleID];
    _player = _app;
    DisableQuiescenceWaits();

    NSFileManager *fm = NSFileManager.defaultManager;
    // A command left behind by a dead client must not fire out of nowhere —
    // the debug channel's stale-sweep rationale.
    for (NSString *name in [fm contentsOfDirectoryAtPath:_dir error:nil]) {
        if ([name hasPrefix:@"vibe-touch-"]) {
            [fm removeItemAtPath:[_dir stringByAppendingPathComponent:name] error:nil];
        }
    }
    NSString *readyPath = [_dir stringByAppendingPathComponent:kReadyMarker];
    [@"1" writeToFile:readyPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kMaxSessionSeconds];
    BOOL done = NO;
    while (!done && deadline.timeIntervalSinceNow > 0) {
        BOOL sawCommand = NO;
        NSArray<NSString *> *names =
                [[fm contentsOfDirectoryAtPath:_dir error:nil] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *name in names) {
            if ([name hasPrefix:@"vibe-touch-"] && [name hasSuffix:@".json"]) {
                sawCommand = YES;
                done = [self handleCommandFile:[_dir stringByAppendingPathComponent:name]] || done;
            }
        }
        if (!sawCommand) {
            [NSThread sleepForTimeInterval:0.05];
        }
    }
    [fm removeItemAtPath:readyPath error:nil];
}

@end
