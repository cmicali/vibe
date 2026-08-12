//
//  VibeiOSDriverTests.m
//  Vibe (iOS)
//
//  Not a test suite: an interactive touch driver in XCUITest clothing — the
//  WebDriverAgent pattern. Touch synthesis on iOS is only available inside
//  the XCUITest harness (XCUICoordinate's gestures ride the testmanagerd
//  session the runner establishes; there is no public UITouch constructor,
//  and replicating testmanagerd's HID injection is private API). So the one
//  "test" here is a command loop: it polls the directory named by the
//  VIBE_DRIVER_DIR environment variable (the app container's tmp, passed by
//  drive-ios.sh as TEST_RUNNER_VIBE_DRIVER_DIR) for vibe-touch-*.json files
//  in the debug channel's {id, args} format, performs the gesture, and
//  replies to vibe-touch-response-<id>.txt. The distinct file prefixes keep
//  the app's own debug-channel drain and launch sweep from touching them.
//
//  Coordinates are app-window POINTS, top-left origin — device pixels from
//  `simctl io booted screenshot` divided by the screen scale.
//

#import <XCTest/XCTest.h>

static NSString *const kAppBundleID = @"com.commonwealthrecordings.Vibe";
static NSString *const kReadyMarker = @"vibe-driver-ready";
// The loop's absolute lifetime; drive-ios.sh stop (the quit verb) is the
// normal exit.
static const NSTimeInterval kMaxSessionSeconds = 4 * 60 * 60;

@interface VibeiOSDriverTests : XCTestCase
@end

@implementation VibeiOSDriverTests {
    XCUIApplication *_app;
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

- (XCUICoordinate *)coordinateAtX:(double)x y:(double)y {
    return [[_app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
            coordinateWithOffset:CGVectorMake(x, y)];
}

// Foregrounds the app if something else is. Lazy, per command: activate on a
// not-running app launches it (without launch-ios.sh's audio-silencing argv),
// so the intended order is launch-ios.sh first, driver second.
- (void)ensureForeground {
    if (_app.state != XCUIApplicationStateRunningForeground) {
        [_app activate];
    }
}

// Returns the reply. tokens[0] is the verb; *quit is set by the quit verb.
- (NSString *)performCommand:(NSArray<NSString *> *)tokens quit:(BOOL *)quit {
    NSString *verb = tokens.firstObject ?: @"";
    double a1 = 0, a2 = 0, a3 = 0, a4 = 0;

    if ([verb isEqualToString:@"quit"]) {
        *quit = YES;
        return JSONString(@{@"ok": @YES, @"quit": @YES});
    }
    if ([verb isEqualToString:@"home"]) {
        [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
        return JSONString(@{@"ok": @YES});
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
    return JSONString(@{@"error": [NSString stringWithFormat:
            @"unknown command '%@'. Commands: tap <x> <y>, double_tap <x> <y>, "
            @"press <x> <y> <seconds>, drag <x1> <y1> <x2> <y2> [seconds], home, quit", verb]});
}

// Returns YES when the command asked the session to end.
- (BOOL)handleCommandFile:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *commandId = [payload isKindOfClass:NSDictionary.class] ? payload[@"id"] : nil;
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
