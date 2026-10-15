//
//  SymbolButtonTests.m
//  VibeTests
//
//  The symbol button's state colors and its rendered glyph, with no window
//  server. Its two layers are the color wash under the symbol's mask and the
//  custom image. State changes are model writes, so they read back at once.
//

#import <XCTest/XCTest.h>

#import "DrawnViewTestSupport.h"
#import "SymbolButton.h"

@interface SymbolButtonTests : XCTestCase
@end

@implementation SymbolButtonTests {
    NSWindow *_window;
    SymbolButton *_button;
}

- (void)setUp {
    [super setUp];
    _window = VibeOffscreenWindow(NSMakeSize(100, 100));
    _button = [[SymbolButton alloc] initWithFrame:NSMakeRect(0, 0, 40, 40)];
    [_window.contentView addSubview:_button];
    _button.symbolPointSize = 24;
    _button.symbolName = @"play.fill";
    [_button layoutSubtreeIfNeeded];
}

- (CALayer *)wash {
    return _button.layer.sublayers[0];
}

- (CALayer *)imageLayer {
    return _button.layer.sublayers[1];
}

- (CGFloat)washAlpha {
    return CGColorGetAlpha(self.wash.backgroundColor);
}

- (NSEvent *)event:(NSEventType)type at:(NSPoint)point {
    if (type == NSEventTypeMouseEntered || type == NSEventTypeMouseExited) {
        return [NSEvent enterExitEventWithType:type location:point modifierFlags:0 timestamp:0
                                  windowNumber:_window.windowNumber context:nil eventNumber:0
                                trackingNumber:0 userData:NULL];
    }
    return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:0
                          windowNumber:_window.windowNumber context:nil eventNumber:0
                            clickCount:1 pressure:1];
}

#pragma mark - States

- (void)testEachStateHasItsOwnStrength {
    NSPoint inside = NSMakePoint(20, 20);
    XCTAssertEqualWithAccuracy(self.washAlpha, 0.55, 1e-6, @"resting");
    [_button mouseEntered:[self event:NSEventTypeMouseEntered at:inside]];
    XCTAssertEqualWithAccuracy(self.washAlpha, 0.8, 1e-6, @"hover");
    [_button mouseDown:[self event:NSEventTypeLeftMouseDown at:inside]];
    XCTAssertEqualWithAccuracy(self.washAlpha, 0.4, 1e-6, @"pressed is half the hover");
    [_button mouseUp:[self event:NSEventTypeLeftMouseUp at:NSMakePoint(80, 80)]];
    XCTAssertEqualWithAccuracy(self.washAlpha, 0.55, 1e-6, @"released outside rests");
    _button.enabled = NO;
    XCTAssertEqualWithAccuracy(self.washAlpha, 0.19, 1e-6, @"disabled");
}

- (void)testADisabledButtonIsClickThroughAndIgnoresAPress {
    _button.enabled = NO;
    XCTAssertNil([_button hitTest:NSMakePoint(20, 20)]);
    [_button mouseDown:[self event:NSEventTypeLeftMouseDown at:NSMakePoint(20, 20)]];
    XCTAssertEqualWithAccuracy(self.washAlpha, 0.19, 1e-6);
    XCTAssertFalse([_button accessibilityPerformPress]);
    _button.enabled = YES;
    _button.alphaValue = 0;
    XCTAssertNil([_button hitTest:NSMakePoint(20, 20)], @"invisible chrome is click-through too");
}

- (void)testOneRestingColorSetsEveryState {
    [_button setSymbolColorsFromRestingColor:[NSColor.redColor colorWithAlphaComponent:0.275]];
    XCTAssertEqualWithAccuracy(self.washAlpha, 0.275, 1e-6);
    [_button mouseEntered:[self event:NSEventTypeMouseEntered at:NSMakePoint(20, 20)]];
    XCTAssertEqualWithAccuracy(self.washAlpha, 0.4, 1e-6, @"0.275 scaled by 0.8 / 0.55");
    NSColor *hover = [NSColor colorWithCGColor:self.wash.backgroundColor];
    XCTAssertGreaterThan([hover colorUsingColorSpace:NSColorSpace.sRGBColorSpace].redComponent, 0.9);
    _button.enabled = NO;
    XCTAssertEqualWithAccuracy(self.washAlpha, 0.095, 1e-6, @"0.275 scaled by 0.19 / 0.55");
}

#pragma mark - Drawing

- (void)testTheSymbolDrawsCenteredAndAnUnknownOneDrawsNothing {
    NSBitmapImageRep *rep = VibeRenderLayer(_button.layer);
    XCTAssertGreaterThan(VibePixel(rep, NO, 20, 20).alphaComponent, 0.3, @"the glyph covers the center");
    XCTAssertEqual(VibePixel(rep, NO, 1, 1).alphaComponent, 0, @"the wash shows only through the glyph");

    _button.symbolName = @"no.such.symbol.vibe";
    XCTAssertNil(self.wash.mask.contents);
    XCTAssertTrue(VibeBitmapIsBlank(VibeRenderLayer(_button.layer)));
    _button.symbolName = @"";
    XCTAssertTrue(VibeBitmapIsBlank(VibeRenderLayer(_button.layer)));
}

- (void)testAnImageReplacesTheSymbolAndFadesByTheSameRatios {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(10, 10) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.greenColor setFill];
        NSRectFill(rect);
        return YES;
    }];
    _button.image = image;
    XCTAssertTrue(self.wash.hidden);
    XCTAssertFalse(self.imageLayer.hidden);
    XCTAssertEqualWithAccuracy(self.imageLayer.opacity, 0.55 / 0.8, 1e-6);
    XCTAssertEqualWithAccuracy(self.imageLayer.frame.size.width, round(24 * 0.8), 1e-9,
                               @"the box a glyph of the point size fills");
    [_button mouseEntered:[self event:NSEventTypeMouseEntered at:NSMakePoint(20, 20)]];
    XCTAssertEqualWithAccuracy(self.imageLayer.opacity, 1, 1e-6);
    _button.enabled = NO;
    XCTAssertEqualWithAccuracy(self.imageLayer.opacity, 0.19 / 0.8, 1e-6);

    _button.image = nil;
    XCTAssertFalse(self.wash.hidden, @"nil returns to the symbol");
    XCTAssertTrue(self.imageLayer.hidden);
}

@end
