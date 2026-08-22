//
//  VibeLinkLabelTests.m
//  VibeTests
//

// The About window's mail link. What is asserted here is the contract a
// VoiceOver or keyboard-only user actually meets — role, name, URL, press,
// focusability — plus the geometry all three input paths share, and the
// no-author fallback where the copyright line names nobody.

#import <XCTest/XCTest.h>

#import "VibeLinkLabel.h"

// activateLink is the single funnel, so overriding it records every path
// without opening Mail.
@interface RecordingLinkLabel : VibeLinkLabel
@property (nonatomic) NSUInteger activations;
@end

@implementation RecordingLinkLabel
- (void)activateLink {
    self.activations++;
}
@end

@interface VibeLinkLabelTests : XCTestCase
@end

@implementation VibeLinkLabelTests {
    RecordingLinkLabel *_label;
    NSString *_copyright;
    NSRange _nameRange;
}

- (void)setUp {
    [super setUp];
    _copyright = @"Copyright © 2026 Christopher Micali. All rights reserved.";
    _nameRange = [_copyright rangeOfString:@"Christopher Micali"];
    _label = [RecordingLinkLabel labelWithString:_copyright];
    _label.frame = NSMakeRect(0, 0, 460, 19);
    [_label setAttributedStringValue:[[NSAttributedString alloc] initWithString:_copyright
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13]}]];
    _label.linkRange = _nameRange;
    _label.linkURL = [NSURL URLWithString:@"mailto:someone@example.com"];
}

#pragma mark - VoiceOver

- (void)testItIsALinkNamedByTheVisibleLine {
    XCTAssertTrue(_label.isAccessibilityElement);
    XCTAssertEqualObjects(_label.accessibilityRole, NSAccessibilityLinkRole);
    XCTAssertEqualObjects(_label.accessibilityLabel, _copyright);
    XCTAssertEqualObjects(_label.accessibilityURL.absoluteString, @"mailto:someone@example.com");
}

- (void)testTheAccessibilityPressActivatesTheLink {
    XCTAssertTrue([_label accessibilityPerformPress]);
    XCTAssertEqual(_label.activations, 1u);
}

#pragma mark - Keyboard

- (void)testItIsFocusableOnlyWhileItCarriesALink {
    XCTAssertTrue(_label.acceptsFirstResponder);
    XCTAssertTrue(_label.canBecomeKeyView);
    _label.linkURL = nil;
    XCTAssertFalse(_label.acceptsFirstResponder);
    XCTAssertFalse(_label.canBecomeKeyView);
}

- (void)testReturnAndSpaceActivateItAndOtherKeysDoNot {
    for (NSString *characters in (@[@"\r", @"\003", @" "])) {
        NSUInteger before = _label.activations;
        [_label keyDown:[self keyEventWithCharacters:characters]];
        XCTAssertEqual(_label.activations, before + 1, @"%@", characters);
    }
    NSUInteger before = _label.activations;
    [_label keyDown:[self keyEventWithCharacters:@"x"]];
    XCTAssertEqual(_label.activations, before);
}

#pragma mark - Pointer

// The focus ring, the accessibility frame and the click target all read
// linkRect, so pinning it pins all three to the same pixels.
- (void)testOnlyTheNameGlyphsAreHitAndTheRestOfTheLineIsTransparent {
    NSRect rect = _label.linkRect;
    XCTAssertFalse(NSIsEmptyRect(rect));
    XCTAssertTrue(NSWidth(rect) < NSWidth(_label.bounds), @"the link is part of the line, not all of it");
    XCTAssertEqualObjects([_label hitTest:NSMakePoint(NSMidX(rect), NSMidY(rect))], _label);
    // Left of the name, and the far right margin: both must fall through so the
    // About window still drags from its background.
    XCTAssertNil([_label hitTest:NSMakePoint(NSMinX(rect) - 6, NSMidY(rect))]);
    XCTAssertNil([_label hitTest:NSMakePoint(NSWidth(_label.bounds) - 1, NSMidY(rect))]);
    XCTAssertTrue(NSEqualRects(_label.focusRingMaskBounds, rect));
}

#pragma mark - The copyright line that names nobody

// The author is matched as a substring of the Info.plist line, so a line
// without it must render as an ordinary label rather than a broken link.
- (void)testWithNoLinkItIsAPlainLabelAndHitTestTransparent {
    _label.linkURL = nil;
    _label.linkRange = NSMakeRange(0, 0);
    XCTAssertTrue(NSIsEmptyRect(_label.linkRect));
    XCTAssertNil([_label hitTest:NSMakePoint(230, 9)]);
    XCTAssertNotEqualObjects(_label.accessibilityRole, NSAccessibilityLinkRole);
    XCTAssertNil(_label.accessibilityURL);
    XCTAssertFalse([_label accessibilityPerformPress]);
    XCTAssertEqual(_label.activations, 0u);
    XCTAssertEqualObjects(_label.stringValue, _copyright, @"the line still renders");
}

#pragma mark - Helpers

- (NSEvent *)keyEventWithCharacters:(NSString *)characters {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown
                            location:NSZeroPoint
                       modifierFlags:0
                           timestamp:0
                        windowNumber:0
                             context:nil
                          characters:characters
         charactersIgnoringModifiers:characters
                           isARepeat:NO
                             keyCode:0];
}

@end
