//
//  WaveformViewTests.mm
//  VibeTests
//
//  The mac waveform view as drawn: its layer tree rendered into a bitmap with
//  no window server. The renderers' own geometry is AudioWaveformTests'; this
//  covers what the view adds over them: the theme it resolves, the playhead
//  line, the three states, and the seek it reports.
//

#import <XCTest/XCTest.h>

#import "DrawnViewTestSupport.h"
#import "WaveformViewInternal.h"
#import "WaveformView+Loading.h"
#import "WaveformTestSupport.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AppTheme.h"
#import "Formatters.h"

// The morph eases on a 60 Hz timer. The tests draw its settled state.
@interface WaveformView (TestSettle)
- (void)settleForTest;
@end

@implementation WaveformView (TestSettle)
- (void)settleForTest {
    [_currentWaveformRenderer settleMorphImmediately];
}
@end

@interface RecordingWaveformDelegate : NSObject <WaveformViewDelegate>
@property (nonatomic) NSMutableArray<NSNumber *> *seeks;
@property (nonatomic) NSUInteger resolutions;
@end

@implementation RecordingWaveformDelegate
- (instancetype)init {
    if ((self = [super init])) {
        _seeks = [NSMutableArray array];
    }
    return self;
}
- (void)waveformView:(WaveformView *)waveformView didSeek:(float)percentage {
    [self.seeks addObject:@(percentage)];
}
- (void)waveformViewDidResolveTheme:(WaveformView *)waveformView {
    self.resolutions++;
}
@end

static const CGFloat kWidth = 400;
static const CGFloat kHeight = 60;

// A loud, constant waveform, so every bar reaches the midline.
static CodableAudioWaveform *LoudWaveform(void) {
    return [[CodableAudioWaveform alloc] initWithWaveform:VibeTestSteadyWaveform(64, {-0.8f, 0.8f, 0.64f})];
}

static NSColor *Opaque(NSColor *color) {
    return [color colorWithAlphaComponent:1];
}

@interface WaveformViewTests : XCTestCase
@end

@implementation WaveformViewTests {
    NSDictionary *_savedTheme;
    AppTheme *_theme;
    WaveformView *_view;
    RecordingWaveformDelegate *_delegate;
}

- (void)setUp {
    [super setUp];
    _theme = AppSettings.sharedInstance.currentTheme;
    _savedTheme = _theme.dictionaryRepresentation;
    _theme.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_MONO;
    _theme.waveformPlayheadLine = NO;
    _theme.waveformCentered = YES;
    _theme.waveformGradient = NO;
    _view = [[WaveformView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)];
    _view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _delegate = [RecordingWaveformDelegate new];
    _view.delegate = _delegate;
}

- (void)tearDown {
    [_theme replaceWithRecord:_savedTheme];
    [super tearDown];
}

- (void)showStyle:(NSString *)style progress:(CGFloat)progress {
    _theme.waveformStyle = style;
    [_view setWaveformStyle:style];
    [_view prepareForWaveformLoad];
    [_view showWaveform:LoudWaveform()];
    _view.progress = progress;
    [_view settleForTest];
}

- (NSBitmapImageRep *)render {
    [_view settleForTest];
    return VibeRenderLayer(_view.layer);
}

- (NSColor *)pixel:(NSBitmapImageRep *)rep x:(CGFloat)x {
    return VibePixel(rep, NO, x, kHeight / 2);
}

#pragma mark - States

- (void)testTheEmptyAndLoadingStatesAreTheMidlineAndExcludeEachOther {
    XCTAssertTrue(VibeBitmapIsBlank([self render]), @"nothing installed yet");

    [_view showEmptyPlaceholder];
    NSBitmapImageRep *empty = [self render];
    XCTAssertGreaterThan([self pixel:empty x:kWidth / 2].alphaComponent, 0, @"the empty midline");
    XCTAssertEqual(VibePixel(empty, NO, kWidth / 2, 5).alphaComponent, 0, @"only the midline is drawn");

    [_view showLoadingIndicator];
    XCTAssertTrue(_view.loadingIndicatorShown);
    XCTAssertGreaterThan([self pixel:[self render] x:kWidth - 2].alphaComponent, 0, @"the loading track");
    [_view showEmptyPlaceholder];
    XCTAssertFalse(_view.loadingIndicatorShown, @"empty replaces loading");

    [_view showLoadingIndicator];
    [_view prepareForWaveformLoad];
    XCTAssertFalse(_view.loadingIndicatorShown);
    XCTAssertTrue(VibeBitmapIsBlank([self render]), @"a load clears both");
}

#pragma mark - Played and unplayed

- (void)testThePlayedSideDiffersAndTheBoundaryIsTheProgress {
    for (NSString *style in @[@"detailed", @"basic", @"cupertino", @"sonic_cirrus"]) {
        [self showStyle:style progress:0.5];
        NSBitmapImageRep *rep = [self render];
        NSColor *played = [self pixel:rep x:kWidth * 0.2];
        NSColor *unplayed = [self pixel:rep x:kWidth * 0.8];
        XCTAssertGreaterThan(played.alphaComponent, 0, @"%@ nonblank", style);
        XCTAssertGreaterThan(unplayed.alphaComponent, 0, @"%@ nonblank", style);
        XCTAssertFalse(VibeColorsClose(played, unplayed, 0.02), @"%@: the halves must differ", style);
        XCTAssertGreaterThan(played.alphaComponent, unplayed.alphaComponent, @"%@: played is brighter", style);

        // The last column drawn in the played color.
        CGFloat boundary = -1;
        for (CGFloat x = 0; x < kWidth; x++) {
            NSColor *c = [self pixel:rep x:x];
            if (c.alphaComponent > 0 && VibeColorsClose(c, played, 0.02)) {
                boundary = x;
            }
        }
        // Bar renderers snap the boundary to a bar.
        XCTAssertEqualWithAccuracy(boundary, kWidth * 0.5, 8, @"%@", style);
    }
}

- (void)testProgressMovesTheBoundaryWithoutANewWaveform {
    [self showStyle:@"detailed" progress:0.25];
    NSColor *before = [self pixel:[self render] x:kWidth * 0.5];
    _view.progress = 0.75;
    NSColor *after = [self pixel:[self render] x:kWidth * 0.5];
    XCTAssertGreaterThan(after.alphaComponent, before.alphaComponent, @"the middle became played");
}

- (void)testAPlayheadLineDrawsEverythingPlayedAndMarksThePosition {
    _theme.waveformPlayheadLine = YES;
    [_theme setColor:NSColor.redColor forBase:kVibeThemeColorWaveformPlayhead dark:YES];
    [self showStyle:@"detailed" progress:0.5];
    NSBitmapImageRep *rep = [self render];
    XCTAssertTrue(VibeColorsClose([self pixel:rep x:kWidth * 0.2], [self pixel:rep x:kWidth * 0.8], 0.02),
                  @"both sides draw as played under a line");
    BOOL found = NO;
    for (CGFloat x = kWidth * 0.5 - 2; x <= kWidth * 0.5 + 2; x++) {
        NSColor *c = [self pixel:rep x:x];
        found = found || (c.redComponent > 0.9 && c.greenComponent < 0.1 && c.blueComponent < 0.1);
    }
    XCTAssertTrue(found, @"the red line sits at the progress");

    [_view prepareForWaveformLoad];
    NSBitmapImageRep *empty = [self render];
    for (CGFloat x = 0; x < kWidth; x++) {
        XCTAssertLessThan([self pixel:empty x:x].redComponent * [self pixel:empty x:x].alphaComponent, 0.5,
                          @"no line with nothing loaded");
    }
}

#pragma mark - Theme

- (void)testTheThemesColorsBeatTheStyle {
    _theme.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;
    [_theme setColor:NSColor.blueColor forBase:kVibeThemeColorWaveformPlayed dark:YES];
    [_theme setColor:[NSColor.redColor colorWithAlphaComponent:0.5] forBase:kVibeThemeColorWaveformUnplayed dark:YES];
    for (NSString *style in @[@"detailed", @"basic", @"cupertino", @"sonic_cirrus"]) {
        [self showStyle:style progress:0.5];
        NSBitmapImageRep *rep = [self render];
        NSColor *played = Opaque([self pixel:rep x:kWidth * 0.2]);
        NSColor *unplayed = Opaque([self pixel:rep x:kWidth * 0.8]);
        XCTAssertGreaterThan(played.blueComponent, 0.9, @"%@ %@", style, played);
        XCTAssertLessThan(played.redComponent, 0.1, @"%@ %@", style, played);
        XCTAssertGreaterThan(unplayed.redComponent, 0.9, @"%@ %@", style, unplayed);
        XCTAssertLessThan(unplayed.blueComponent, 0.1, @"%@ %@", style, unplayed);
    }
}

// 3-Band's palette is the theme's band wells, not the style's own.
- (void)testTheThemesBandWellsBeatThreeBandsPalette {
    _theme.waveformShadeOverlaps = NO;
    for (NSString *base in @[kVibeThemeColorWaveformLow, kVibeThemeColorWaveformMid, kVibeThemeColorWaveformHigh]) {
        [_theme setColor:NSColor.greenColor forBase:base dark:YES];
    }
    [self showStyle:@"three_band" progress:0.5];
    NSColor *played = Opaque([self pixel:[self render] x:kWidth * 0.2]);
    XCTAssertGreaterThan(played.greenComponent, 0.9, @"%@", played);
    XCTAssertLessThan(played.redComponent, 0.1, @"%@", played);
    XCTAssertLessThan(played.blueComponent, 0.1, @"%@", played);
}

// Album Art keeps the played side at the base and colors what is to come.
- (void)testTheAlbumArtColorRidesTheArtworkInstall {
    _theme.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART;
    [self showStyle:@"detailed" progress:0.5];
    NSColor *noArt = Opaque([self pixel:[self render] x:kWidth * 0.8]);
    XCTAssertEqualWithAccuracy(noArt.redComponent, noArt.greenComponent, 0.02, @"no art is Mono's gray");
    NSUInteger resolutions = _delegate.resolutions;

    _view.artworkThemeColor = [NSColor colorWithSRGBRed:0.1 green:0.8 blue:0.2 alpha:1];
    XCTAssertEqual(_delegate.resolutions, resolutions, @"the color waits for the install's refresh");
    [_view refreshThemeColors];
    XCTAssertEqual(_delegate.resolutions, resolutions + 1);
    NSBitmapImageRep *rep = [self render];
    NSColor *unplayed = Opaque([self pixel:rep x:kWidth * 0.8]);
    XCTAssertGreaterThan(unplayed.greenComponent, unplayed.redComponent + 0.2, @"green art, green bars: %@", unplayed);
    NSColor *played = Opaque([self pixel:rep x:kWidth * 0.2]);
    XCTAssertEqualWithAccuracy(played.redComponent, played.greenComponent, 0.02, @"the played side stays the base");
}

- (void)testTheAppearanceFlipReResolvesTheTheme {
    [self showStyle:@"detailed" progress:0.5];
    NSColor *dark = Opaque([self pixel:[self render] x:kWidth * 0.2]);
    NSUInteger resolutions = _delegate.resolutions;
    _view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    XCTAssertGreaterThan(_delegate.resolutions, resolutions);
    NSColor *light = Opaque([self pixel:[self render] x:kWidth * 0.2]);
    XCTAssertGreaterThan(dark.redComponent, 0.5, @"Mono is white on dark");
    XCTAssertLessThan(light.redComponent, 0.5, @"and black on light");
}

#pragma mark - Seek

- (void)testAClickSeeksToItsFraction {
    NSWindow *window = VibeOffscreenWindow(NSMakeSize(kWidth, kHeight));
    [window.contentView addSubview:_view];
    [self showStyle:@"detailed" progress:0];
    XCTAssertEqualObjects(AppSettings.sharedInstance.waveformDragBehavior, SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW);
    NSPoint point = NSMakePoint(kWidth * 0.3, kHeight / 2);
    for (NSEventType type : {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp}) {
        NSEvent *event = [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:0
                                        windowNumber:window.windowNumber context:nil eventNumber:0
                                          clickCount:1 pressure:1];
        type == NSEventTypeLeftMouseDown ? [_view mouseDown:event] : [_view mouseUp:event];
    }
    XCTAssertEqual(_delegate.seeks.count, 1u);
    XCTAssertEqualWithAccuracy(_delegate.seeks.firstObject.floatValue, 0.3, 1e-6);
    XCTAssertEqualWithAccuracy(_view.progress, 0, 1e-9, @"the position comes back through the owner");
}

- (void)testAccessibilityStepsReportASeekOnlyWithAWaveform {
    XCTAssertFalse([_view accessibilityPerformIncrement]);
    [self showStyle:@"detailed" progress:0.5];
    XCTAssertEqualObjects(_view.accessibilityValue, [Formatters.sharedInstance percentString:0.5]);
    XCTAssertTrue([_view accessibilityPerformIncrement]);
    XCTAssertTrue([_view accessibilityPerformDecrement]);
    XCTAssertEqualObjects(_delegate.seeks, (@[@0.55f, @0.45f]));
    _view.progress = 1;
    XCTAssertFalse([_view accessibilityPerformIncrement], @"already at the end");
}

@end
