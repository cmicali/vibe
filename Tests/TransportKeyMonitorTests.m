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
static const unsigned short kKeyA = 0, kKeyS = 1, kKeyQ = 12, kKeyW = 13, kKeyE = 14, kKeyR = 15, kKeyT = 17;
static const unsigned short kKeyO = 31, kKeyK = 40, kKeyN = 45, kKeyM = 46, kKeySpace = 49, kKeyReturn = 36;
static const unsigned short kKeyDelete = 51, kKeyForwardDelete = 117, kKeyDown = 125;
static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand;

@interface TransportKeyMonitorTests : XCTestCase
// Duck collaborators for the real key monitor: no NSWindow or audio engine.
@property (nonatomic, getter=isPlaylistShown) BOOL playlistShown;
@property (nonatomic) BOOL hasFXGraph;
@property (nonatomic) BOOL lowKillActive;
@property (nonatomic) BOOL lowKillBoostActive;
@property (nonatomic) BOOL reverbSendActive;
@property (nonatomic) BOOL delaySendActive;
@property (nonatomic) BOOL shortDelaySendActive;
@property (nonatomic) NSMutableArray<NSString *> *commands;
// Commands whose menu item is hidden, so performing them answers NO.
@property (nonatomic) NSSet<NSString *> *hiddenCommands;
@end

@implementation TransportKeyMonitorTests

- (void)setUp {
    self.commands = [NSMutableArray array];
    self.hiddenCommands = [NSSet set];
    AppSettings.sharedInstance.shortcutOverrides = @{};
}

- (void)tearDown {
    AppSettings.sharedInstance.shortcutOverrides = @{};
}

- (NSWindow *)window { return (id)self; }
- (NSResponder *)firstResponder { return nil; }
- (id)audioPlayer { return self; }
- (id)fx { return self.hasFXGraph ? self : nil; }
- (BOOL)performMenuCommandWithIdentifier:(NSString *)identifier {
    if ([self.hiddenCommands containsObject:identifier]) {
        return NO;
    }
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

// A Command press: typed is what the layout's ⌘ layer types, unmodified what
// it types without the modifiers.
- (NSEvent *)command:(unsigned short)keyCode typed:(NSString *)typed unmodified:(NSString *)unmodified
           modifiers:(NSEventModifierFlags)modifiers repeat:(BOOL)repeat {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers
                          timestamp:10 windowNumber:0 context:nil characters:typed
        charactersIgnoringModifiers:unmodified isARepeat:repeat keyCode:keyCode];
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

// Holding ⌘R must not cycle Off → All → One: a character default goes
// through the monitor and its repeat rule, whatever the layout types.
- (void)testCharacterDefaultsArePerformedOnceWhenHeld {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    XCTAssertNil([monitor handleKeyEvent:[self command:kKeyR typed:@"r" unmodified:@"r" modifiers:kCmd repeat:NO]
                                inWindow:self.window]);
    XCTAssertNil([monitor handleKeyEvent:[self command:kKeyR typed:@"r" unmodified:@"r" modifiers:kCmd repeat:YES]
                                inWindow:self.window]);
    // Greek types ρ unmodified and r under its ⌘ layer.
    XCTAssertNil([monitor handleKeyEvent:[self command:kKeyR typed:@"r" unmodified:@"ρ" modifiers:kCmd repeat:NO]
                                inWindow:self.window]);
    // Option bends the typed letter; the unmodified one still matches.
    XCTAssertNil([monitor handleKeyEvent:[self command:kKeyS typed:@"ß" unmodified:@"s"
            modifiers:kCmd | NSEventModifierFlagOption repeat:NO] inWindow:self.window]);
    // Dvorak – QWERTY ⌘: the key that types r types o under Command, and is Open.
    XCTAssertNil([monitor handleKeyEvent:[self command:kKeyO typed:@"o" unmodified:@"r" modifiers:kCmd repeat:NO]
                                inWindow:self.window]);
    NSEvent *shifted = [self command:kKeyR typed:@"r" unmodified:@"R" modifiers:kCmd | NSEventModifierFlagShift repeat:NO];
    XCTAssertEqual([monitor handleKeyEvent:shifted inWindow:self.window], shifted, @"⇧⌘R is unbound");
    XCTAssertEqualObjects(self.commands, (@[kVibeMenuRepeat, kVibeMenuRepeat, kVibeMenuShuffle, kVibeMenuOpen]));

    // Re-recorded as a key code, Repeat holds the same way.
    [self.commands removeAllObjects];
    AppSettings.sharedInstance.shortcutOverrides = @{kVibeMenuRepeat: @(VibeShortcutMake(kKeyK, kCmd))};
    for (NSNumber *repeat in @[@NO, @YES]) {
        XCTAssertNil([monitor handleKeyEvent:[self command:kKeyK typed:@"k" unmodified:@"k" modifiers:kCmd
                repeat:repeat.boolValue] inWindow:self.window]);
    }
    XCTAssertEqualObjects(self.commands, @[kVibeMenuRepeat]);
}

// Outside the player window the menu bar performs a binding; the monitor only
// holds back a Command binding's repeat, never a bare key's, which may be
// typing.
- (void)testElsewhereOnlyACommandBindingsRepeatIsHeldBack {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    NSEvent *first = [self command:kKeyR typed:@"r" unmodified:@"r" modifiers:kCmd repeat:NO];
    XCTAssertEqual([monitor handleKeyEvent:first inWindow:nil], first);
    XCTAssertNil([monitor handleKeyEvent:[self command:kKeyR typed:@"r" unmodified:@"r" modifiers:kCmd repeat:YES]
                                inWindow:nil]);
    NSEvent *typing = [self key:kKeyN characters:@"n" type:NSEventTypeKeyDown time:10 repeat:YES modifiers:0];
    XCTAssertEqual([monitor handleKeyEvent:typing inWindow:nil], typing);
    AppSettings.sharedInstance.shortcutOverrides = @{kVibeMenuNextTrack: @(VibeShortcutMake(kKeyN, kCmd))};
    NSEvent *next = [self command:kKeyN typed:@"n" unmodified:@"n" modifiers:kCmd repeat:YES];
    XCTAssertEqual([monitor handleKeyEvent:next inWindow:nil], next, @"Next repeats");
    XCTAssertEqualObjects(self.commands, @[], @"the menu bar performs");
}

// Convert to FLAC bound to K with Convert switched off: its item is hidden,
// so K acts as unbound rather than being eaten.
- (void)testAHiddenCommandPassesItsKeyOn {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    AppSettings.sharedInstance.shortcutOverrides = @{kVibeMenuConvertToFLAC: @(VibeShortcutMake(kKeyK, 0))};
    self.hiddenCommands = [NSSet setWithObject:kVibeMenuConvertToFLAC];
    NSEvent *k = [self down:kKeyK];
    XCTAssertEqual([monitor handleKeyEvent:k inWindow:self.window], k);
    self.hiddenCommands = [NSSet set];
    XCTAssertNil([monitor handleKeyEvent:k inWindow:self.window]);
    XCTAssertEqualObjects(self.commands, @[kVibeMenuConvertToFLAC]);
}

// M has no meaning of its own in any build: unbound it passes, bound it acts.
- (void)testMIsAnOrdinaryKey {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    NSEvent *m = [self down:kKeyM];
    XCTAssertEqual([monitor handleKeyEvent:m inWindow:self.window], m);
    AppSettings.sharedInstance.shortcutOverrides = @{kVibeMenuShowFileInfo: @(VibeShortcutMake(kKeyM, 0))};
    XCTAssertNil([monitor handleKeyEvent:m inWindow:self.window]);
    XCTAssertEqualObjects(self.commands, @[kVibeMenuShowFileInfo]);
}

@end
