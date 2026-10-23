//
//  PitchFaderViewTests.m
//  VibeTests
//
//  The pitch fader drawn into a bitmap, and its gestures, with no window
//  server. The window is deferred and never ordered front. Then what the app
//  pushes into the fader and its panel.
//

#import <XCTest/XCTest.h>

#import "DrawnViewTestSupport.h"
#import "PitchControlPanel.h"
#import "PitchFaderView.h"

@interface RecordingFaderDelegate : NSObject <PitchFaderViewDelegate>
@property (nonatomic) NSMutableArray<NSNumber *> *pitches;
@property (nonatomic) NSUInteger ends;
@end

@implementation RecordingFaderDelegate
- (instancetype)init {
    if ((self = [super init])) {
        _pitches = [NSMutableArray array];
    }
    return self;
}
- (void)pitchFaderView:(PitchFaderView *)faderView didChangePitch:(float)pitch {
    [self.pitches addObject:@(pitch)];
}
- (void)pitchFaderViewDidEndAdjusting:(PitchFaderView *)faderView {
    self.ends++;
}
@end

static const CGFloat kWidth = 100;
static const CGFloat kHeight = 200;
// The knob's travel is inset half a knob plus 2 at each end.
static const CGFloat kTravelTop = 13;
static const CGFloat kTravelBottom = kHeight - 13;

@interface PitchFaderViewTests : XCTestCase
@end

@implementation PitchFaderViewTests {
    NSWindow *_window;
    PitchFaderView *_fader;
    RecordingFaderDelegate *_delegate;
}

- (void)setUp {
    [super setUp];
    _window = VibeOffscreenWindow(NSMakeSize(kWidth, kHeight));
    _fader = [[PitchFaderView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)];
    [_window.contentView addSubview:_fader];
    _delegate = [RecordingFaderDelegate new];
    _fader.delegate = _delegate;
}

- (CGFloat)yForPitch:(float)pitch {
    return kTravelTop + (pitch + _fader.maxPitch) / (2 * _fader.maxPitch) * (kTravelBottom - kTravelTop);
}

// The knob's white index line, one point above the knob's center.
- (BOOL)indexLineAt:(CGFloat)y in:(NSBitmapImageRep *)rep {
    NSColor *c = VibePixel(rep, YES, kWidth / 2, y - 0.5);
    return c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9;
}

// The quartz-lock LED, left of the scale at the zero line.
- (NSColor *)ledIn:(NSBitmapImageRep *)rep {
    return VibePixel(rep, YES, kWidth / 2 - 36, [self yForPitch:0]);
}

- (void)send:(NSEventType)type atPitch:(float)pitch clicks:(NSInteger)clicks {
    // The window is unflipped and the fader is flipped.
    NSPoint point = NSMakePoint(kWidth / 2 + 30, kHeight - [self yForPitch:pitch]);
    NSEvent *event = [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:0
                                    windowNumber:_window.windowNumber context:nil eventNumber:0
                                      clickCount:clicks pressure:1];
    switch (type) {
        case NSEventTypeLeftMouseDown: [_fader mouseDown:event]; break;
        case NSEventTypeLeftMouseDragged: [_fader mouseDragged:event]; break;
        default: [_fader mouseUp:event]; break;
    }
}

#pragma mark - Drawing

- (void)testTheKnobSitsWhereThePitchSays {
    for (NSNumber *range in @[@8, @16]) {
        _fader.maxPitch = range.floatValue;
        for (NSNumber *pitch in @[@0, @(-range.floatValue), @(range.floatValue), @(range.floatValue / 2)]) {
            _fader.pitch = pitch.floatValue;
            NSBitmapImageRep *rep = VibeRenderView(_fader);
            XCTAssertTrue([self indexLineAt:[self yForPitch:pitch.floatValue] in:rep], @"±%@ at %@", range, pitch);
            if (pitch.floatValue != 0) {
                XCTAssertFalse([self indexLineAt:[self yForPitch:0] in:rep], @"±%@ at %@", range, pitch);
            }
        }
    }
}

- (void)testTheLEDIsLitOnlyAtExactlyZero {
    NSColor *lit = [self ledIn:VibeRenderView(_fader)];
    XCTAssertGreaterThan(lit.greenComponent, 0.9);
    _fader.pitch = 0.1f;
    NSColor *unlit = [self ledIn:VibeRenderView(_fader)];
    XCTAssertLessThan(unlit.greenComponent, 0.4);
    XCTAssertGreaterThan(unlit.greenComponent, unlit.redComponent, @"unlit is still a dark green");
}

- (void)testTheHardwareLookIgnoresTheAppearance {
    _fader.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSBitmapImageRep *dark = VibeRenderView(_fader);
    _fader.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSBitmapImageRep *light = VibeRenderView(_fader);
    XCTAssertEqualObjects(dark.TIFFRepresentation, light.TIFFRepresentation);
}

#pragma mark - Range

- (void)testThePitchClampsToTheRange {
    _fader.pitch = 20;
    XCTAssertEqual(_fader.pitch, 8);
    _fader.maxPitch = 16;
    _fader.pitch = -20;
    XCTAssertEqual(_fader.pitch, -16);
    _fader.maxPitch = 8;
    XCTAssertEqual(_fader.pitch, -8, @"narrowing the range clamps the pitch");
    _fader.maxPitch = 0;
    XCTAssertEqual(_fader.maxPitch, 8, @"a zero range would divide by zero");
    _fader.maxPitch = NAN;
    XCTAssertEqual(_fader.maxPitch, 8);
    XCTAssertEqual(_delegate.pitches.count, 0u, @"setting never fires the delegate");
}

#pragma mark - Gestures

- (void)testAClickOnTheScaleJumpsAndOneGestureEndsOnce {
    [self send:NSEventTypeLeftMouseDown atPitch:4 clicks:1];
    XCTAssertEqualObjects(_delegate.pitches, (@[@4]));
    [self send:NSEventTypeLeftMouseDragged atPitch:5 clicks:1];
    [self send:NSEventTypeLeftMouseDragged atPitch:5 clicks:1];
    XCTAssertEqualObjects(_delegate.pitches, (@[@4, @5]), @"a repeated pitch does not re-fire");
    XCTAssertEqual(_delegate.ends, 0u);
    [self send:NSEventTypeLeftMouseUp atPitch:5 clicks:1];
    XCTAssertEqual(_delegate.ends, 1u);
}

- (void)testTheCenterDetentAndTheEndsSnap {
    [self send:NSEventTypeLeftMouseDown atPitch:3 clicks:1];
    [self send:NSEventTypeLeftMouseDragged atPitch:0.3f clicks:1];
    XCTAssertEqual(_fader.pitch, 0, @"inside the detent");
    // Grabbed the knob at its center, so dragging past the end clamps.
    [self send:NSEventTypeLeftMouseDragged atPitch:30 clicks:1];
    [self send:NSEventTypeLeftMouseDragged atPitch:40 clicks:1];
    XCTAssertEqual(_fader.pitch, 8);
    XCTAssertEqualObjects(_delegate.pitches, (@[@3, @0, @8]));
    [self send:NSEventTypeLeftMouseUp atPitch:40 clicks:1];
}

- (void)testADoubleClickResetsAndEnds {
    _fader.pitch = 5;
    [self send:NSEventTypeLeftMouseDown atPitch:5 clicks:2];
    XCTAssertEqual(_fader.pitch, 0);
    XCTAssertEqualObjects(_delegate.pitches, (@[@0]));
    XCTAssertEqual(_delegate.ends, 1u);
}

- (void)testAccessibilityStepsByHalfAPercentAndEndsEachPress {
    XCTAssertEqualObjects(_fader.accessibilityRole, NSAccessibilitySliderRole);
    XCTAssertTrue([_fader accessibilityPerformIncrement]);
    XCTAssertEqual(_fader.pitch, 0.5f);
    XCTAssertEqual(_delegate.ends, 1u);
    _fader.pitch = 8;
    XCTAssertFalse([_fader accessibilityPerformIncrement], @"at the end of the travel");
    XCTAssertEqual(_delegate.ends, 1u);
    _fader.maxPitch = 16;
    _fader.pitch = -0.5f;
    XCTAssertTrue([_fader accessibilityPerformIncrement]);
    XCTAssertEqual(_fader.pitch, 0, @"half a percent lands on exactly zero");
}

#pragma mark - What the app pushes

static NSString *SignedPercent(double pitch) {
    return [NSString stringWithFormat:@"%+.1f%%", pitch];
}

- (void)testTheAppNamesTheFaderAndFormatsItsValue {
    _fader.pitch = 2.5f;
    XCTAssertEqualObjects(_fader.accessibilityValue, @2.5, @"with no formatter, the bare value");
    _fader.accessibilityLabel = @"Pitch";
    _fader.accessibilityValueFormatter = ^NSString *(double value) {
        return SignedPercent(value);
    };
    XCTAssertEqualObjects(_fader.accessibilityLabel, @"Pitch");
    XCTAssertEqualObjects(_fader.accessibilityValue, @"+2.5%");
}

- (void)testThePanelPushesItsTextToTheFaderAndTheReadout {
    PitchControlPanel *panel = [[PitchControlPanel alloc] initWithFrame:NSMakeRect(0, 0, kPitchPanelWidth, 400)];
    panel.title = @"PITCH";
    panel.faderAccessibilityLabel = @"Pitch";
    panel.pitchFormatter = ^NSString *(double pitch) {
        return SignedPercent(pitch);
    };
    panel.pitch = -1.5f;
    PitchFaderView *fader = nil;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSView *view in panel.subviews) {
        if ([view isKindOfClass:PitchFaderView.class]) {
            fader = (PitchFaderView *)view;
        }
        else if ([view isKindOfClass:NSTextField.class]) {
            [texts addObject:((NSTextField *)view).stringValue];
        }
    }
    XCTAssertEqualObjects(panel.title, @"PITCH");
    XCTAssertEqualObjects(texts, (@[@"PITCH", @"-1.5%"]), @"the title, then the readout");
    XCTAssertEqualObjects(fader.accessibilityLabel, @"Pitch");
    XCTAssertEqualObjects(fader.accessibilityValue, @"-1.5%", @"the spoken value is the readout");
}

- (void)testThePanelRoundsItsRightCornersByThePushedRadius {
    PitchControlPanel *panel = [[PitchControlPanel alloc] initWithFrame:NSMakeRect(0, 0, kPitchPanelWidth, 400)];
    NSColor *square = VibePixel(VibeRenderView(panel), NO, kPitchPanelWidth - 1, 399);
    XCTAssertGreaterThan(square.alphaComponent, 0.9);
    panel.cornerRadius = 16;
    NSBitmapImageRep *rep = VibeRenderView(panel);
    XCTAssertLessThan(VibePixel(rep, NO, kPitchPanelWidth - 1, 399).alphaComponent, 0.1, @"top right");
    XCTAssertLessThan(VibePixel(rep, NO, kPitchPanelWidth - 1, 0).alphaComponent, 0.1, @"bottom right");
    XCTAssertGreaterThan(VibePixel(rep, NO, 2, 399).alphaComponent, 0.9, @"the left edge stays square");
}

@end
