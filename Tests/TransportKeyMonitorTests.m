//
//  TransportKeyMonitorTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "TransportKeyMonitor.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "ShortcutRules.h"

// HIToolbox key codes, as the monitor matches them.
static const unsigned short kKeyA = 0, kKeyQ = 12, kKeyW = 13, kKeyE = 14, kKeyR = 15, kKeyT = 17;
static const unsigned short kKeyK = 40, kKeyN = 45, kKeyM = 46, kKeySpace = 49, kKeyReturn = 36;
static const unsigned short kKeyDelete = 51, kKeyForwardDelete = 117, kKeyDown = 125;

@interface TransportKeyMonitorTests : XCTestCase
// Duck collaborators for the real key monitor: no NSWindow or audio engine.
@property (nonatomic, getter=isPlaylistShown) BOOL playlistShown;
@property (nonatomic) BOOL hasFXGraph;
@property (nonatomic) BOOL lowKillActive;
@property (nonatomic) BOOL lowKillBoostActive;
@property (nonatomic) BOOL reverbSendActive;
@property (nonatomic) BOOL delaySendActive;
@property (nonatomic) BOOL shortDelaySendActive;
@property (nonatomic) NSUInteger markerReads;
@property (nonatomic) NSMutableArray<NSString *> *commands;
@end

@implementation TransportKeyMonitorTests

- (void)setUp {
    self.commands = [NSMutableArray array];
    AppSettings.sharedInstance.shortcutOverrides = @{};
}

- (void)tearDown {
    AppSettings.sharedInstance.shortcutOverrides = @{};
}

- (NSWindow *)window { return (id)self; }
- (NSResponder *)firstResponder { return nil; }
- (id)audioPlayer { return self; }
- (id)fx { return self.hasFXGraph ? self : nil; }
- (id)currentTrack { return nil; }
- (double)position { return 0; }
- (BOOL)isPlaying { return NO; }
- (BOOL)isLoading { return NO; }
- (NSDictionary *)bitPerfectReportDictionary { self.markerReads++; return @{}; }
- (BOOL)performMenuCommandWithIdentifier:(NSString *)identifier {
    [self.commands addObject:identifier];
    return YES;
}

// characters is what the layout typed, which the monitor ignores for every
// binding: only the key code matches.
- (NSEvent *)key:(unsigned short)keyCode characters:(NSString *)characters type:(NSEventType)type
            time:(NSTimeInterval)time repeat:(BOOL)repeat modifiers:(NSEventModifierFlags)modifiers {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:modifiers
                          timestamp:time windowNumber:0 context:nil characters:characters
        charactersIgnoringModifiers:characters isARepeat:repeat keyCode:keyCode];
}

- (NSEvent *)down:(unsigned short)keyCode {
    return [self key:keyCode characters:@"x" type:NSEventTypeKeyDown time:10 repeat:NO modifiers:0];
}

- (void)testEffectKeysTapLatchAndHeldRepeatRestoresTheOriginalState {
    BOOL enabled = AppSettings.sharedInstance.audioFXEnabled;
    AppSettings.sharedInstance.audioFXEnabled = YES;
    self.hasFXGraph = YES;
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    NSDictionary *keys = @{@(kKeyQ): @"lowKillActive", @(kKeyW): @"lowKillBoostActive",
                           @(kKeyE): @"reverbSendActive", @(kKeyR): @"delaySendActive",
                           @(kKeyT): @"shortDelaySendActive"};
    @try {
        for (NSNumber *key in keys) for (NSNumber *initial in @[@NO, @YES]) {
            for (NSNumber *duration in @[@0.1, @0.5]) {
                unsigned short code = key.unsignedShortValue;
                [self setValue:initial forKey:keys[key]];
                XCTAssertNil([monitor handleKeyEvent:[self key:code characters:@"q" type:NSEventTypeKeyDown
                        time:10 repeat:NO modifiers:0] inWindow:self.window]);
                XCTAssertEqual([[self valueForKey:keys[key]] boolValue], !initial.boolValue);
                XCTAssertNil([monitor handleKeyEvent:[self key:code characters:@"q" type:NSEventTypeKeyDown
                        time:10.05 repeat:YES modifiers:0] inWindow:self.window]);
                // A modifier pressed during the hold must not hide its release.
                XCTAssertNil([monitor handleKeyEvent:[self key:code characters:@"q" type:NSEventTypeKeyUp
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

// Bound with Shift, the effect's release still matches when Shift went up first.
- (void)testARemappedEffectKeyReleasesWithoutItsModifier {
    BOOL enabled = AppSettings.sharedInstance.audioFXEnabled;
    AppSettings.sharedInstance.audioFXEnabled = YES;
    self.hasFXGraph = YES;
    AppSettings.sharedInstance.shortcutOverrides = @{kVibeMenuFXReverb: @(VibeShortcutMake(kKeyE, NSEventModifierFlagShift))};
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    @try {
        NSEvent *bare = [self down:kKeyE];
        XCTAssertEqual([monitor handleKeyEvent:bare inWindow:self.window], bare, @"bare E is unbound now");
        XCTAssertFalse(self.reverbSendActive);
        XCTAssertNil([monitor handleKeyEvent:[self key:kKeyE characters:@"E" type:NSEventTypeKeyDown time:10
                repeat:NO modifiers:NSEventModifierFlagShift] inWindow:self.window]);
        XCTAssertTrue(self.reverbSendActive);
        XCTAssertNil([monitor handleKeyEvent:[self key:kKeyE characters:@"e" type:NSEventTypeKeyUp time:11
                repeat:NO modifiers:0] inWindow:self.window]);
        XCTAssertFalse(self.reverbSendActive, @"held, so it reverts");
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
            for (NSNumber *key in @[@(kKeyQ), @(kKeyE), @(kKeyR)]) {
                [monitor handleKeyEvent:[self down:key.unsignedShortValue] inWindow:self.window];
            }
            [monitor handleKeyEvent:[self key:kKeyR characters:@"r" type:NSEventTypeKeyUp time:10.1
                    repeat:NO modifiers:0] inWindow:self.window]; // deliberately latched
            [[NSNotificationCenter defaultCenter] postNotificationName:notification object:self.window];
            XCTAssertFalse(self.lowKillActive);
            XCTAssertTrue(self.reverbSendActive);
            XCTAssertTrue(self.delaySendActive);
            NSEvent *late = [self key:kKeyQ characters:@"q" type:NSEventTypeKeyUp time:11 repeat:NO modifiers:0];
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
            NSEvent *down = [self down:kKeyW];
            NSEvent *up = [self key:kKeyW characters:@"w" type:NSEventTypeKeyUp time:11 repeat:NO modifiers:0];
            XCTAssertEqual([monitor handleKeyEvent:down inWindow:self.window], down);
            XCTAssertEqual([monitor handleKeyEvent:up inWindow:self.window], up);
            XCTAssertFalse(self.lowKillBoostActive);
        }
    } @finally {
        AppSettings.sharedInstance.audioFXEnabled = enabled;
    }
}

// Remove goes through its menu item, whose validation needs the playlist
// showing; a held delete takes one gesture's rows.
- (void)testDeleteRepeatIsSwallowedAndHiddenOrModifiedDeletesDoNotRemove {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    for (NSNumber *keyCode in @[@(kKeyDelete), @(kKeyForwardDelete)]) {
        unsigned short code = keyCode.unsignedShortValue;
        self.playlistShown = YES;
        [self.commands removeAllObjects];
        NSEvent *down = [self down:code];
        XCTAssertEqual([monitor handleKeyEvent:down inWindow:nil], down);
        XCTAssertNil([monitor handleKeyEvent:down inWindow:self.window]);
        XCTAssertNil([monitor handleKeyEvent:[self key:code characters:@"x" type:NSEventTypeKeyDown time:11
                repeat:YES modifiers:0] inWindow:self.window]);
        self.playlistShown = NO;
        XCTAssertNil([monitor handleKeyEvent:down inWindow:self.window]);
        self.playlistShown = YES;
        NSEvent *modified = [self key:code characters:@"x" type:NSEventTypeKeyDown time:12 repeat:NO
                            modifiers:NSEventModifierFlagCommand];
        XCTAssertEqual([monitor handleKeyEvent:modified inWindow:self.window], modified);
        XCTAssertEqualObjects(self.commands, @[kVibeMenuEditRemoveFromPlaylist]);
    }
}

// Space, P and Tab would flutter when held; the skips and track steps repeat.
- (void)testOnlyTheSkipsAndTrackStepsRepeat {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    for (NSNumber *repeat in @[@NO, @YES]) {
        for (NSNumber *keyCode in @[@(kKeySpace), @(kKeyN), @(kKeyA)]) {
            XCTAssertNil([monitor handleKeyEvent:[self key:keyCode.unsignedShortValue characters:@" "
                    type:NSEventTypeKeyDown time:13 repeat:repeat.boolValue modifiers:0] inWindow:self.window]);
        }
    }
    XCTAssertEqualObjects(self.commands, (@[kVibeMenuPlay, kVibeMenuNextTrack, kVibeMenuSkipForward,
                                            kVibeMenuNextTrack, kVibeMenuSkipForward]));
}

// The physical key decides: a Greek layout's characters on the default key
// codes still skip, and a remap moves the command off its old key.
- (void)testBindingsMatchThePhysicalKeyAndFollowARemap {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    XCTAssertNil([monitor handleKeyEvent:[self key:kKeyA characters:@"α" type:NSEventTypeKeyDown time:10
            repeat:NO modifiers:0] inWindow:self.window]);
    XCTAssertEqualObjects(self.commands, @[kVibeMenuSkipForward]);

    AppSettings.sharedInstance.shortcutOverrides = @{
        kVibeMenuSkipForward: @(VibeShortcutMake(kKeyK, NSEventModifierFlagOption)),
    };
    NSEvent *a = [self down:kKeyA];
    XCTAssertEqual([monitor handleKeyEvent:a inWindow:self.window], a);
    NSEvent *k = [self down:kKeyK];
    XCTAssertEqual([monitor handleKeyEvent:k inWindow:self.window], k, @"Option is part of the binding");
    XCTAssertNil([monitor handleKeyEvent:[self key:kKeyK characters:@"˚" type:NSEventTypeKeyDown time:10
            repeat:NO modifiers:NSEventModifierFlagOption | NSEventModifierFlagCapsLock] inWindow:self.window]);
    XCTAssertEqualObjects(self.commands, (@[kVibeMenuSkipForward, kVibeMenuSkipForward]));
}

// An unassigned default passes its key on; with the playlist collapsed the
// physical playlist keys are swallowed whatever is bound, so none reaches the
// off-screen table.
- (void)testUnassignedKeysPassAndCollapsedPlaylistKeysAreSwallowed {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    AppSettings.sharedInstance.shortcutOverrides = @{
        kVibeMenuPlaySelected: @(kVibeShortcutNone),
        kVibeMenuNextTrack: @(kVibeShortcutNone),
    };
    NSEvent *n = [self down:kKeyN];
    XCTAssertEqual([monitor handleKeyEvent:n inWindow:self.window], n);
    self.playlistShown = YES;
    NSEvent *ret = [self down:kKeyReturn];
    XCTAssertEqual([monitor handleKeyEvent:ret inWindow:self.window], ret);
    NSEvent *arrow = [self down:kKeyDown];
    XCTAssertEqual([monitor handleKeyEvent:arrow inWindow:self.window], arrow, @"the table's own");
    self.playlistShown = NO;
    XCTAssertNil([monitor handleKeyEvent:ret inWindow:self.window]);
    XCTAssertNil([monitor handleKeyEvent:arrow inWindow:self.window]);
    XCTAssertNil([monitor handleKeyEvent:[self down:76] inWindow:self.window], @"keypad Enter");
    XCTAssertEqualObjects(self.commands, @[]);
}

// A key-code binding that lands on a fixed system shortcut after a layout
// switch yields to it.
- (void)testAReservedCharacterBeatsAKeyCodeBinding {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    AppSettings.sharedInstance.shortcutOverrides = @{
        kVibeMenuShowFileInfo: @(VibeShortcutMake(kKeyK, NSEventModifierFlagCommand)),
    };
    NSEvent *quit = [self key:kKeyK characters:@"q" type:NSEventTypeKeyDown time:10 repeat:NO
                    modifiers:NSEventModifierFlagCommand];
    XCTAssertEqual([monitor handleKeyEvent:quit inWindow:self.window], quit);
    XCTAssertNil([monitor handleKeyEvent:[self key:kKeyK characters:@"k" type:NSEventTypeKeyDown time:10 repeat:NO
            modifiers:NSEventModifierFlagCommand] inWindow:self.window]);
    XCTAssertEqualObjects(self.commands, @[kVibeMenuShowFileInfo]);
}

- (void)testBetaMarkerWorksWithGreekKeyboardAndIgnoresRepeatAndModifiers {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                modifierFlags:attempt == 2 ? NSEventModifierFlagCommand : 0
                timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:0 context:nil
                characters:@"μ" charactersIgnoringModifiers:@"μ" isARepeat:attempt == 1 keyCode:kKeyM];
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
