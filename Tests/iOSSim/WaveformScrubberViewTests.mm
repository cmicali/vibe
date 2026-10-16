// WaveformScrubberView and its Bitmap, Gestures and Loading categories, on
// UIKit. What is drawn is read back from the layer tree: the baked bitmaps
// are layer contents, and the loading indicator is layers of its own.

#import "IOSSimTestCase.h"

#import <vector>

#import "AppSettings.h"
#import "AudioWaveform.h"
#import "WaveformScrubberViewInternal.h"
#import "WaveformZoomMath.h"

@interface ScrubberEvents : NSObject <WaveformScrubberViewDelegate>
@property (nonatomic, readonly) NSMutableArray<NSNumber *> *seeks;
@property (nonatomic, readonly) NSMutableArray<NSNumber *> *scrubbing;
@property (nonatomic, readonly) NSMutableArray<NSNumber *> *scrubProgress;
@property (nonatomic, readonly) NSMutableArray<NSNumber *> *fractions;
@end

@implementation ScrubberEvents
- (instancetype)init {
    if ((self = [super init])) {
        _seeks = [NSMutableArray array];
        _scrubbing = [NSMutableArray array];
        _scrubProgress = [NSMutableArray array];
        _fractions = [NSMutableArray array];
    }
    return self;
}
- (void)waveformScrubberView:(WaveformScrubberView *)view didSeek:(float)percentage {
    [_seeks addObject:@(percentage)];
}
- (void)waveformScrubberView:(WaveformScrubberView *)view didChangeScrubbing:(BOOL)scrubbing {
    [_scrubbing addObject:@(scrubbing)];
}
- (void)waveformScrubberView:(WaveformScrubberView *)view didScrubToProgress:(CGFloat)progress {
    [_scrubProgress addObject:@(progress)];
}
- (void)waveformScrubberView:(WaveformScrubberView *)view didChangeVisibleFraction:(CGFloat)fraction {
    [_fractions addObject:@(fraction)];
}
@end

// A recognizer whose state, touches and location the test sets. The view's
// handlers read only these.
@interface ScriptedTap : UITapGestureRecognizer
@property (nonatomic) UIGestureRecognizerState scriptedState;
@property (nonatomic) CGPoint scriptedLocation;
@end

@implementation ScriptedTap
- (UIGestureRecognizerState)state { return _scriptedState; }
- (CGPoint)locationInView:(UIView *)view { return _scriptedLocation; }
@end

@interface ScriptedPinch : UIPinchGestureRecognizer
@property (nonatomic) UIGestureRecognizerState scriptedState;
@property (nonatomic) CGFloat scriptedScale;
@property (nonatomic) NSUInteger scriptedTouches;
@property (nonatomic) CGPoint scriptedLocation;
@end

@implementation ScriptedPinch
- (UIGestureRecognizerState)state { return _scriptedState; }
- (CGFloat)scale { return _scriptedScale; }
- (NSUInteger)numberOfTouches { return _scriptedTouches; }
- (CGPoint)locationInView:(UIView *)view { return _scriptedLocation; }
@end

// The alpha-weighted mean color of a bitmap, and how much of it is drawn.
typedef struct {
    double red, green, blue;
    double coverage;
} VibeImageTint;

static VibeImageTint VibeTintOfImage(CGImageRef image) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    std::vector<uint8_t> pixels(width * height * 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels.data(), width, height, 8, width * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    double r = 0, g = 0, b = 0, a = 0;
    size_t drawn = 0;
    for (size_t i = 0; i < width * height; i++) {
        uint8_t alpha = pixels[i * 4 + 3];
        if (alpha == 0) continue;
        drawn++;
        r += pixels[i * 4];
        g += pixels[i * 4 + 1];
        b += pixels[i * 4 + 2];
        a += alpha;
    }
    if (a == 0) {
        return (VibeImageTint){0, 0, 0, 0};
    }
    return (VibeImageTint){r / a, g / a, b / a, (double)drawn / (double)(width * height)};
}

@interface WaveformScrubberViewTests : IOSSimTestCase
@end

@implementation WaveformScrubberViewTests {
    WaveformScrubberView *_view;
    ScrubberEvents *_events;
}

static const CGFloat kWidth = 320;
static const CGFloat kHeight = 120;

- (void)setUp {
    [super setUp];
    AppSettings *settings = AppSettings.sharedInstance;
    settings.waveformStyle = SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT;
    [settings setWaveformTheme:SETTINGS_VALUE_WAVEFORM_THEME_MONO forWidget:NO];
    _view = [[WaveformScrubberView alloc] initWithFrame:CGRectMake(0, 100, kWidth, kHeight)];
    // Pinned, so Mono's played side is white whatever the simulator shows.
    _view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _events = [[ScrubberEvents alloc] init];
    _view.delegate = _events;
    [self.window addSubview:_view];
    [_view layoutIfNeeded];
}

- (void)tearDown {
    [_view removeFromSuperview];
    _view = nil;
    [super tearDown];
}

// A loud, varied envelope; complete, as an archive is.
static CodableAudioWaveform *CompleteWaveform(void) {
    auto waveform = std::make_unique<AudioWaveform>(64, 1, false, 44100);
    for (size_t i = 0; i < 512; i++) {
        float level = 0.3f + 0.6f * (float)fabs(sin((double)i / 9.0)), lo = -level;
        waveform->appendBin(&lo, &level, level * level * 64, nullptr, 64);
    }
    waveform->markComplete();
    return [[CodableAudioWaveform alloc] initWithWaveform:std::move(waveform)];
}

- (UIScrollView *)scroll {
    for (UIView *subview in _view.subviews) {
        if ([subview isKindOfClass:UIScrollView.class]) {
            return (UIScrollView *)subview;
        }
    }
    return nil;
}

- (NSArray *)bakedImages {
    return VibeLayerImages(self.scroll.layer);
}

- (void)showAndBake:(CodableAudioWaveform *)waveform {
    [_view prepareForWaveformLoad];
    [_view showWaveform:waveform animated:NO];
    XCTAssertTrue([self eventually:^BOOL { return [self->_view isShowingCompleteWaveform:waveform]; }],
                  @"the bake never installed");
    // The reset ends any interaction, which reports itself: start clean.
    _events = [[ScrubberEvents alloc] init];
    _view.delegate = _events;
}

// The most saturated tint among the standing bitmaps: the played side's.
- (VibeImageTint)strongestTint {
    VibeImageTint best = {0, 0, 0, 0};
    double bestSpread = -1;
    for (id image in self.bakedImages) {
        VibeImageTint tint = VibeTintOfImage((__bridge CGImageRef)image);
        double spread = MAX(MAX(tint.red, tint.green), tint.blue) - MIN(MIN(tint.red, tint.green), tint.blue);
        if (tint.coverage > 0 && spread > bestSpread) {
            best = tint;
            bestSpread = spread;
        }
    }
    return best;
}

#pragma mark - The bitmap

- (void)testAWaveformBakesANonblankBitmapAndEnablesScrubbing {
    XCTAssertFalse(_view.isScrubbingEnabled);
    XCTAssertFalse(self.scroll.scrollEnabled, @"an empty strip must hand the pager its swipe");
    [self showAndBake:CompleteWaveform()];
    XCTAssertTrue(_view.isScrubbingEnabled);
    XCTAssertTrue(self.scroll.scrollEnabled);
    NSArray *images = self.bakedImages;
    XCTAssertGreaterThan(images.count, 0u);
    double coverage = 0;
    for (id image in images) {
        coverage = MAX(coverage, VibeTintOfImage((__bridge CGImageRef)image).coverage);
    }
    XCTAssertGreaterThan(coverage, 0.05, @"the bake drew next to nothing");
}

- (void)testAResetDropsTheBitmapAndTheWaveform {
    [self showAndBake:CompleteWaveform()];
    [_view prepareForWaveformLoad];
    XCTAssertEqual(self.bakedImages.count, 0u);
    XCTAssertFalse(_view.isScrubbingEnabled);
    XCTAssertEqual(_view.progress, 0);
}

#pragma mark - Zoom and the playhead

- (CGFloat)expectedVirtualWidth {
    CGFloat scale = _view.traitCollection.displayScale;
    CGFloat floor = VibeWaveformMinimumVisibleFraction(kWidth, kHeight, scale);
    return kWidth / VibeWaveformClampVisibleFraction(_view.visibleFraction, floor);
}

// The play position is the view's center: progress p puts the track's point
// p under it, at the content offset the zoom math predicts.
- (void)testProgressParksTheContentUnderTheCenteredPlayhead {
    [self showAndBake:CompleteWaveform()];
    CGFloat virtualWidth = [self expectedVirtualWidth];
    XCTAssertEqualWithAccuracy(self.scroll.contentSize.width, virtualWidth, 0.5);
    for (NSNumber *progress in @[@0, @0.25, @0.5, @1]) {
        _view.progress = progress.doubleValue;
        XCTAssertEqualWithAccuracy(self.scroll.contentOffset.x,
                                   progress.doubleValue * virtualWidth - kWidth / 2, 1.0, @"%@", progress);
    }
    // Past the end, as at a track's end: the content stays at the edge.
    _view.progress = 1.4;
    XCTAssertEqualWithAccuracy(self.scroll.contentOffset.x, virtualWidth - kWidth / 2, 1.0);
}

// The request is kept as asked. What is drawn stops at the bake's floor, so a
// rotation can deepen it again (WaveformUI/iOS/AGENTS.md).
- (void)testAZoomPastTheFloorDrawsAtTheFloorAndKeepsTheRequest {
    CGFloat scale = _view.traitCollection.displayScale;
    CGFloat floor = VibeWaveformMinimumVisibleFraction(kWidth, kHeight, scale);
    XCTAssertGreaterThan(floor, kVibeWaveformMinimumZoomFraction);
    _view.visibleFraction = kVibeWaveformMinimumZoomFraction;
    XCTAssertEqual(_view.visibleFraction, kVibeWaveformMinimumZoomFraction);
    XCTAssertEqualWithAccuracy(_view.effectiveVisibleFraction, floor, 1e-9);
    XCTAssertEqualWithAccuracy(self.scroll.contentSize.width, kWidth / floor, 0.5);
}

- (void)testAGarbageZoomRequestReadsAsTheDefault {
    for (NSNumber *garbage in @[@0, @(-1), @2, @(NAN)]) {
        _view.visibleFraction = 0.3;
        _view.visibleFraction = garbage.doubleValue;
        XCTAssertEqual(_view.visibleFraction, kVibeWaveformDefaultZoomFraction, @"%@", garbage);
    }
}

#pragma mark - The theme

// The root guarantee: the theme beats the style's palette, and it is read
// again on a sync, re-baking the bitmap.
- (void)testTheThemeColorsTheBakeAndASyncRecolorsIt {
    [self showAndBake:CompleteWaveform()];
    VibeImageTint mono = [self strongestTint];
    XCTAssertLessThan(fabs(mono.red - mono.blue), 0.08, @"Mono is gray");

    [AppSettings.sharedInstance setWaveformTheme:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE forWidget:NO];
    NSArray *before = self.bakedImages;
    [_view syncWaveformTheme];
    XCTAssertTrue([self eventually:^BOOL {
        return ![self.bakedImages isEqualToArray:before] && self.bakedImages.count > 0;
    }]);
    VibeImageTint orange = [self strongestTint];
    XCTAssertGreaterThan(orange.red - orange.blue, 0.3, @"Orange is not orange: %f %f %f",
                         orange.red, orange.green, orange.blue);
}

// album_art: the art's color arrives on the view, and only that theme reads
// it. No art resolves to Mono's answer.
- (void)testTheArtworkColorRecolorsOnlyUnderAlbumArt {
    [AppSettings.sharedInstance setWaveformTheme:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART forWidget:NO];
    [self showAndBake:CompleteWaveform()];
    VibeImageTint noArt = [self strongestTint];
    XCTAssertLessThan(fabs(noArt.red - noArt.blue), 0.08, @"no art draws Mono");

    NSArray *before = self.bakedImages;
    _view.artworkThemeColor = [UIColor colorWithRed:0.1 green:0.8 blue:0.2 alpha:1];
    XCTAssertTrue([self eventually:^BOOL { return ![self.bakedImages isEqualToArray:before]; }]);
    VibeImageTint green = [self strongestTint];
    XCTAssertGreaterThan(green.green - green.red, 0.25, @"%f %f %f", green.red, green.green, green.blue);

    [AppSettings.sharedInstance setWaveformTheme:SETTINGS_VALUE_WAVEFORM_THEME_MONO forWidget:NO];
    [_view syncWaveformTheme];
    XCTAssertTrue([self eventually:^BOOL {
        VibeImageTint tint = [self strongestTint];
        return fabs(tint.red - tint.green) < 0.08;
    }], @"Mono ignores the art");
}

#pragma mark - Loading

- (NSUInteger)hostLayerCount {
    return _view.layer.sublayers.count;
}

// A slow open keeps its indicator over a waveform that lands mid-open, and
// settlement takes it down.
- (void)testPlaybackLoadingOutlivesTheArrivingWaveformUntilSettlement {
    [_view prepareForWaveformLoad];
    NSUInteger resting = self.hostLayerCount;
    _view.playbackLoading = YES;
    XCTAssertGreaterThan(self.hostLayerCount, resting, @"no indicator for a slow open");

    CodableAudioWaveform *waveform = CompleteWaveform();
    [_view showWaveform:waveform animated:NO];
    XCTAssertTrue([self eventually:^BOOL { return [self->_view isShowingCompleteWaveform:waveform]; }]);
    XCTAssertGreaterThan(self.hostLayerCount, resting, @"the bitmap took the open's indicator down");

    _view.playbackLoading = NO;
    XCTAssertEqual(self.hostLayerCount, resting);
}

// Without a slow open, the picture ends the shimmer, and a download fill
// outlives it until its monitor ends.
- (void)testADownloadFillOutlivesTheShimmerUntilItEnds {
    [_view prepareForWaveformLoad];
    NSUInteger resting = self.hostLayerCount;
    [_view showLoadingIndicator];
    [_view setLoadingProgress:0.4f];
    XCTAssertGreaterThan(self.hostLayerCount, resting);
    CodableAudioWaveform *waveform = CompleteWaveform();
    [_view showWaveform:waveform animated:NO];
    XCTAssertTrue([self eventually:^BOOL { return [self->_view isShowingCompleteWaveform:waveform]; }]);
    XCTAssertGreaterThan(self.hostLayerCount, resting, @"the fill went with the shimmer");
    [_view setLoadingProgress:-1];
    XCTAssertEqual(self.hostLayerCount, resting);
}

- (void)testAPlainLoadEndsWithTheBitmap {
    [_view prepareForWaveformLoad];
    NSUInteger resting = self.hostLayerCount;
    [_view showLoadingIndicator];
    XCTAssertGreaterThan(self.hostLayerCount, resting);
    CodableAudioWaveform *waveform = CompleteWaveform();
    [_view showWaveform:waveform animated:NO];
    XCTAssertTrue([self eventually:^BOOL { return self.hostLayerCount == resting; }]);
}

#pragma mark - Gestures

- (void)testATapSeeksToTheTappedPointOnlyWithAWaveform {
    ScriptedTap *tap = [[ScriptedTap alloc] initWithTarget:nil action:NULL];
    tap.scriptedState = UIGestureRecognizerStateEnded;
    tap.scriptedLocation = CGPointMake(100, 10);
    [_view handleTap:tap];
    XCTAssertEqual(_events.seeks.count, 0u, @"an empty strip seeks nowhere");

    [self showAndBake:CompleteWaveform()];
    [_view handleTap:tap];
    XCTAssertEqual(_events.seeks.count, 1u);
    XCTAssertEqualWithAccuracy(_events.seeks.firstObject.doubleValue, 100 / [self expectedVirtualWidth], 1e-3);

    tap.scriptedLocation = CGPointMake(-500, 10);
    [_view handleTap:tap];
    XCTAssertEqual(_events.seeks.lastObject.floatValue, 0.0f, @"clamped to the track");

    tap.scriptedState = UIGestureRecognizerStateBegan;
    [_view handleTap:tap];
    XCTAssertEqual(_events.seeks.count, 2u, @"only an ended tap seeks");
}

// A drag commits one seek, on its end, and holds the pager for its length.
- (void)testADragSeeksOnceWhenItEnds {
    [self showAndBake:CompleteWaveform()];
    _view.progress = 0.3;
    id<UIScrollViewDelegate> delegate = (id<UIScrollViewDelegate>)_view;
    [delegate scrollViewWillBeginDragging:self.scroll];
    XCTAssertEqualObjects(_events.scrubbing, @[@YES]);
    XCTAssertEqual(_events.seeks.count, 0u);
    [delegate scrollViewDidEndDragging:self.scroll willDecelerate:YES];
    XCTAssertEqual(_events.seeks.count, 0u, @"a coast has not ended");
    [delegate scrollViewDidEndDecelerating:self.scroll];
    XCTAssertEqual(_events.seeks.count, 1u);
    XCTAssertEqualWithAccuracy(_events.seeks.firstObject.doubleValue, 0.3, 1e-3);
    XCTAssertEqualObjects(_events.scrubbing, (@[@YES, @NO]));
    [delegate scrollViewDidEndDecelerating:self.scroll];
    XCTAssertEqual(_events.seeks.count, 1u, @"one seek per gesture");
}

- (void)testACancelledInteractionReleasesThePagerWithoutSeeking {
    [self showAndBake:CompleteWaveform()];
    [(id<UIScrollViewDelegate>)_view scrollViewWillBeginDragging:self.scroll];
    [_view cancelInteraction];
    XCTAssertEqual(_events.seeks.count, 0u);
    XCTAssertEqualObjects(_events.scrubbing.lastObject, @NO);
    XCTAssertTrue(self.scroll.scrollEnabled);
}

// A pure zoom: no seek, the new request reported once on release.
- (void)testAPinchZoomsAboutThePlayheadAndReportsTheRequestOnRelease {
    [self showAndBake:CompleteWaveform()];
    _view.progress = 0.5;
    CGFloat start = _view.visibleFraction;
    ScriptedPinch *pinch = [[ScriptedPinch alloc] initWithTarget:nil action:NULL];
    pinch.scriptedTouches = 2;
    pinch.scriptedState = UIGestureRecognizerStateBegan;
    [_view handlePinch:pinch];
    XCTAssertEqualObjects(_events.scrubbing, @[@YES]);
    XCTAssertFalse(_view.isScrubbing, @"a pure zoom keeps following playback");

    pinch.scriptedState = UIGestureRecognizerStateChanged;
    pinch.scriptedScale = 2;
    [_view handlePinch:pinch];
    XCTAssertEqualWithAccuracy(_view.visibleFraction, start / 2, 1e-9);
    XCTAssertEqualWithAccuracy(self.scroll.contentOffset.x,
                               0.5 * [self expectedVirtualWidth] - kWidth / 2, 1.0, @"the zoom left the playhead");

    pinch.scriptedState = UIGestureRecognizerStateEnded;
    [_view handlePinch:pinch];
    XCTAssertEqual(_events.seeks.count, 0u);
    XCTAssertEqualObjects(_events.scrubbing, (@[@YES, @NO]));
    XCTAssertEqual(_events.fractions.count, 1u);
    XCTAssertEqualWithAccuracy(_events.fractions.firstObject.doubleValue, start / 2, 1e-9);
}

// The finger a pinch leaves behind scrubs past the slop, and the pinch's
// release commits that seek once.
- (void)testTheFingerLeftByAPinchScrubsPastTheSlop {
    [self showAndBake:CompleteWaveform()];
    _view.progress = 0.5;
    ScriptedPinch *pinch = [[ScriptedPinch alloc] initWithTarget:nil action:NULL];
    pinch.scriptedTouches = 2;
    pinch.scriptedState = UIGestureRecognizerStateBegan;
    [_view handlePinch:pinch];
    pinch.scriptedState = UIGestureRecognizerStateChanged;
    pinch.scriptedScale = 1;
    pinch.scriptedTouches = 1;
    pinch.scriptedLocation = CGPointMake(160, 10);
    [_view handlePinch:pinch];
    pinch.scriptedLocation = CGPointMake(165, 10);
    [_view handlePinch:pinch];
    XCTAssertFalse(_view.isScrubbing, @"a wobble inside the slop is no scrub");
    pinch.scriptedLocation = CGPointMake(200, 10);
    [_view handlePinch:pinch];
    pinch.scriptedLocation = CGPointMake(100, 10);
    [_view handlePinch:pinch];
    XCTAssertTrue(_view.isScrubbing);
    XCTAssertGreaterThan(_events.scrubProgress.count, 0u);
    XCTAssertEqual(_events.seeks.count, 0u, @"no seek with the finger down");
    pinch.scriptedState = UIGestureRecognizerStateEnded;
    [_view handlePinch:pinch];
    XCTAssertEqual(_events.seeks.count, 1u);
    XCTAssertGreaterThan(_events.seeks.firstObject.doubleValue, 0.5, @"dragging left moves forward");
}

- (void)testAPinchOnAnEmptyStripDoesNothing {
    ScriptedPinch *pinch = [[ScriptedPinch alloc] initWithTarget:nil action:NULL];
    pinch.scriptedTouches = 2;
    pinch.scriptedState = UIGestureRecognizerStateBegan;
    [_view handlePinch:pinch];
    pinch.scriptedState = UIGestureRecognizerStateEnded;
    [_view handlePinch:pinch];
    XCTAssertEqual(_events.scrubbing.count, 0u);
    XCTAssertEqual(_events.fractions.count, 0u);
}

#pragma mark - Accessibility

- (void)testVoiceOverStepsSeekOnlyWithAWaveform {
    XCTAssertEqual(_view.accessibilityTraits, UIAccessibilityTraitNone);
    [_view accessibilityIncrement];
    XCTAssertEqual(_events.seeks.count, 0u);
    [self showAndBake:CompleteWaveform()];
    XCTAssertEqual(_view.accessibilityTraits, UIAccessibilityTraitAdjustable);
    _view.progress = 0.5;
    [_view accessibilityIncrement];
    [_view accessibilityDecrement];
    XCTAssertEqual(_events.seeks.count, 2u);
    XCTAssertEqualWithAccuracy(_events.seeks[0].doubleValue, 0.55, 1e-6);
    XCTAssertEqualWithAccuracy(_events.seeks[1].doubleValue, 0.45, 1e-6);
}

@end
