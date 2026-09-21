//
//  TransportKeyMonitorTests.m
//  VibeTests
//

// The real bare-key handler, with constructed events and duck collaborators.
// No native windows, audio engine, or posted input are needed.

#import <XCTest/XCTest.h>

#import "TransportKeyMonitor.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"

@interface TransportKeyMonitorTests : XCTestCase
// Duck collaborators for the real key monitor: no NSWindow or audio engine.
@property (nonatomic, getter=isPlaylistShown) BOOL playlistShown;
@property (nonatomic) BOOL hasFXGraph;
@property (nonatomic) BOOL lowKillActive;
@property (nonatomic) BOOL lowKillBoostActive;
@property (nonatomic) BOOL reverbSendActive;
@property (nonatomic) BOOL delaySendActive;
@property (nonatomic) BOOL shortDelaySendActive;
@property (nonatomic) NSUInteger removals;
@property (nonatomic) NSUInteger plays;
@property (nonatomic) NSUInteger markerReads;
@end

@implementation TransportKeyMonitorTests

- (NSWindow *)window { return (id)self; }
- (NSResponder *)firstResponder { return nil; }
- (id)audioPlayer { return self; }
- (id)fx { return self.hasFXGraph ? self : nil; }
- (id)currentTrack { return nil; }
- (double)position { return 0; }
- (BOOL)isPlaying { return NO; }
- (BOOL)isLoading { return NO; }
- (NSDictionary *)bitPerfectReportDictionary { self.markerReads++; return @{}; }
- (void)removeSelectedPlaylistTracks:(id)sender { self.removals++; }
- (void)playPause:(id)sender { self.plays++; }

- (NSEvent *)key:(NSString *)characters type:(NSEventType)type time:(NSTimeInterval)time
         repeat:(BOOL)repeat modifiers:(NSEventModifierFlags)modifiers {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:modifiers
                          timestamp:time windowNumber:0 context:nil characters:characters
        charactersIgnoringModifiers:characters isARepeat:repeat keyCode:0];
}

- (void)testEffectKeysTapLatchAndHeldRepeatRestoresTheOriginalState {
    BOOL enabled = AppSettings.sharedInstance.audioFXEnabled;
    AppSettings.sharedInstance.audioFXEnabled = YES;
    self.hasFXGraph = YES;
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    NSDictionary *keys = @{@"q": @"lowKillActive", @"w": @"lowKillBoostActive",
                           @"e": @"reverbSendActive", @"r": @"delaySendActive",
                           @"t": @"shortDelaySendActive"};
    @try {
        for (NSString *key in keys) for (NSNumber *initial in @[@NO, @YES]) {
            for (NSNumber *duration in @[@0.1, @0.5]) {
                [self setValue:initial forKey:keys[key]];
                XCTAssertNil([monitor handleKeyEvent:[self key:key type:NSEventTypeKeyDown
                        time:10 repeat:NO modifiers:0] inWindow:self.window]);
                XCTAssertEqual([[self valueForKey:keys[key]] boolValue], !initial.boolValue);
                XCTAssertNil([monitor handleKeyEvent:[self key:key type:NSEventTypeKeyDown
                        time:10.05 repeat:YES modifiers:0] inWindow:self.window]);
                // A modifier pressed during the hold must not hide its release.
                XCTAssertNil([monitor handleKeyEvent:[self key:key type:NSEventTypeKeyUp
                        time:10 + duration.doubleValue repeat:NO modifiers:NSEventModifierFlagCommand]
                        inWindow:self.window]);
                XCTAssertEqual([[self valueForKey:keys[key]] boolValue],
                               duration.doubleValue < 0.35 ? !initial.boolValue : initial.boolValue);
            }
        }
    } @finally {
        AppSettings.sharedInstance.audioFXEnabled = enabled;
    }
}

- (void)testLostEffectReleaseRevertsHeldKeysButPreservesTaps {
    BOOL enabled = AppSettings.sharedInstance.audioFXEnabled;
    AppSettings.sharedInstance.audioFXEnabled = YES;
    self.hasFXGraph = YES;
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    @try {
        for (NSString *notification in @[NSWindowDidResignKeyNotification,
                                        NSMenuDidBeginTrackingNotification, NSWindowWillMoveNotification]) {
            self.lowKillActive = NO;
            self.reverbSendActive = YES;
            self.delaySendActive = NO;
            for (NSString *key in @[@"q", @"e", @"r"]) {
                [monitor handleKeyEvent:[self key:key type:NSEventTypeKeyDown time:10 repeat:NO modifiers:0]
                               inWindow:self.window];
            }
            [monitor handleKeyEvent:[self key:@"r" type:NSEventTypeKeyUp time:10.1 repeat:NO modifiers:0]
                           inWindow:self.window]; // deliberately latched
            [[NSNotificationCenter defaultCenter] postNotificationName:notification object:self.window];
            XCTAssertFalse(self.lowKillActive);
            XCTAssertTrue(self.reverbSendActive);
            XCTAssertTrue(self.delaySendActive);
            NSEvent *late = [self key:@"q" type:NSEventTypeKeyUp time:11 repeat:NO modifiers:0];
            XCTAssertEqual([monitor handleKeyEvent:late inWindow:self.window], late);
        }
    } @finally {
        AppSettings.sharedInstance.audioFXEnabled = enabled;
    }
}

- (void)testDisabledEffectKeysPassThroughWithoutLatching {
    BOOL enabled = AppSettings.sharedInstance.audioFXEnabled;
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    @try {
        for (NSNumber *graph in @[@NO, @YES]) {
            self.hasFXGraph = graph.boolValue;
            AppSettings.sharedInstance.audioFXEnabled = !graph.boolValue;
            NSEvent *down = [self key:@"w" type:NSEventTypeKeyDown time:10 repeat:NO modifiers:0];
            NSEvent *up = [self key:@"w" type:NSEventTypeKeyUp time:11 repeat:NO modifiers:0];
            XCTAssertEqual([monitor handleKeyEvent:down inWindow:self.window], down);
            XCTAssertEqual([monitor handleKeyEvent:up inWindow:self.window], up);
            XCTAssertFalse(self.lowKillBoostActive);
        }
    } @finally {
        AppSettings.sharedInstance.audioFXEnabled = enabled;
    }
}

- (void)testDeleteRepeatIsSwallowedAndHiddenOrModifiedDeletesDoNotRemove {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    for (NSNumber *character in @[@(NSDeleteCharacter), @(NSDeleteFunctionKey)]) {
        NSString *key = [NSString stringWithFormat:@"%C", character.unsignedShortValue];
        self.playlistShown = YES;
        self.removals = 0;
        NSEvent *down = [self key:key type:NSEventTypeKeyDown time:10 repeat:NO modifiers:0];
        XCTAssertEqual([monitor handleKeyEvent:down inWindow:nil], down);
        XCTAssertEqual(self.removals, 0u);
        XCTAssertNil([monitor handleKeyEvent:down inWindow:self.window]);
        XCTAssertNil([monitor handleKeyEvent:[self key:key type:NSEventTypeKeyDown time:11
                repeat:YES modifiers:0] inWindow:self.window]);
        self.playlistShown = NO;
        XCTAssertNil([monitor handleKeyEvent:down inWindow:self.window]);
        self.playlistShown = YES;
        NSEvent *modified = [self key:key type:NSEventTypeKeyDown time:12 repeat:NO
                                  modifiers:NSEventModifierFlagCommand];
        XCTAssertEqual([monitor handleKeyEvent:modified inWindow:self.window], modified);
        XCTAssertEqual(self.removals, 1u);
    }
    for (NSNumber *repeat in @[@NO, @YES]) {
        XCTAssertNil([monitor handleKeyEvent:[self key:@" " type:NSEventTypeKeyDown time:13
                repeat:repeat.boolValue modifiers:0] inWindow:self.window]);
    }
    XCTAssertEqual(self.plays, 2u, @"transport still honors repeat");
}

- (void)testBetaMarkerWorksWithGreekKeyboardAndIgnoresRepeatAndModifiers {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                modifierFlags:attempt == 2 ? NSEventModifierFlagCommand : 0
                timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:0 context:nil
                characters:@"μ" charactersIgnoringModifiers:@"μ" isARepeat:attempt == 1 keyCode:46];
        NSEvent *result = [monitor handleKeyEvent:event inWindow:self.window];
#if VIBE_VERBOSE_LOGGING
        XCTAssertEqual(result, attempt == 2 ? event : nil);
        XCTAssertEqual(self.markerReads, 1u);
#else
        XCTAssertEqual(result, event);
        XCTAssertEqual(self.markerReads, 0u);
#endif
    }
}
@end
