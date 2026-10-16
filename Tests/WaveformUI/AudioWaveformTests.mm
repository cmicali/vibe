#import <XCTest/XCTest.h>

#import "AudioWaveform.h"
#import "WaveformTestSupport.h"
#import "WaveformMorphEngine.h"
#import "WaveformRendererRegistry.h"
#import "DetailedWaveformRenderer.h"
#import "ThreeBandWaveformRenderer.h"
#import "AppSettings.h"
#import "VibeStrings.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <random>
#include <vector>

@interface AudioWaveformTests : XCTestCase
@end

@implementation AudioWaveformTests

- (WaveformRenderer *)rendererForStyle:(NSString *)identifier {
    CALayer *host = [CALayer layer];
    host.bounds = CGRectMake(0, 0, 512, 80);
    return [WaveformRendererRegistry rendererForResolvedIdentifier:identifier
            layer:host bounds:host.bounds isDark:YES];
}

// A layer's contents as 32-bit ARGB pixels in host order, rows from the top,
// and the frame they cover.
struct VibeTestPicture {
    size_t width = 0;
    size_t height = 0;
    std::vector<uint32_t> pixels;
    CGRect frame = CGRectZero;

    uint32_t at(size_t x, size_t row) const { return pixels[row * width + x]; }
    uint32_t alpha(size_t x, size_t row) const { return at(x, row) >> 24; }
    uint32_t rgb(size_t x, size_t row) const { return at(x, row) & 0xffffff; }
};

static VibeTestPicture VibePictureOf(CALayer *layer) {
    VibeTestPicture picture;
    CGImageRef image = (__bridge CGImageRef)layer.contents;
    if (!image) {
        return picture;
    }
    picture.width = CGImageGetWidth(image);
    picture.height = CGImageGetHeight(image);
    picture.frame = layer.frame;
    NSData *data = CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
    picture.pixels.resize(picture.width * picture.height);
    for (size_t row = 0; row < picture.height; row++) {
        memcpy(&picture.pixels[row * picture.width],
               (const uint8_t *)data.bytes + row * CGImageGetBytesPerRow(image), picture.width * sizeof(uint32_t));
    }
    return picture;
}

// Where the picture's alpha reaches minimum, in its superlayer's y-up points.
static CGRect VibeLitBounds(const VibeTestPicture &picture, uint32_t minimum = 1) {
    size_t left = SIZE_MAX, right = 0, top = SIZE_MAX, bottom = 0;
    for (size_t row = 0; row < picture.height; row++) {
        for (size_t x = 0; x < picture.width; x++) {
            if (picture.alpha(x, row) >= minimum) {
                left = MIN(left, x);
                right = MAX(right, x);
                top = MIN(top, row);
                bottom = MAX(bottom, row);
            }
        }
    }
    if (left == SIZE_MAX) {
        return CGRectNull;
    }
    CGFloat px = picture.frame.size.width / picture.width, py = picture.frame.size.height / picture.height;
    return CGRectMake(CGRectGetMinX(picture.frame) + left * px, CGRectGetMaxY(picture.frame) - (bottom + 1) * py,
                      (right - left + 1) * px, (bottom - top + 1) * py);
}

// The coverage across columns [x0, x1) of a row, in pixels.
static CGFloat VibeLitWidth(const VibeTestPicture &picture, size_t x0, size_t x1, size_t row) {
    CGFloat sum = 0;
    for (size_t x = x0; x < MIN(x1, picture.width); x++) {
        sum += picture.alpha(x, row) / 255.0;
    }
    return sum;
}

// The Detailed family's mask, whose contents are the picture's coverage.
static CALayer *VibeMaskLayer(WaveformRenderer *renderer) {
    return renderer.parentLayer.sublayers.firstObject.mask;
}

#pragma mark - Resize and content transitions

- (NSData *)previewPixelsForStyle:(NSString *)style theme:(WaveformTheme *)theme
                      barDensity:(CGFloat)density barWidth:(CGFloat)width normalize:(BOOL)normalize gainDB:(float)gainDB {
    return [self previewPixelsForStyle:style theme:theme barDensity:density barWidth:width centered:YES
                             normalize:normalize gainDB:gainDB];
}

- (NSData *)previewPixelsForStyle:(NSString *)style theme:(WaveformTheme *)theme
                      barDensity:(CGFloat)density barWidth:(CGFloat)width centered:(BOOL)centered
                       normalize:(BOOL)normalize gainDB:(float)gainDB {
    CGImageRef image = [WaveformRendererRegistry newPreviewForIdentifier:style dark:YES
            theme:theme barDensity:density barWidth:width centered:centered normalize:normalize gainDB:gainDB];
    XCTAssertTrue(image != NULL);
    if (!image) return NSData.data;
    XCTAssertEqual(CGImageGetWidth(image), 720u);
    XCTAssertEqual(CGImageGetHeight(image), 128u);
    NSData *pixels = CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
    CGImageRelease(image);
    return pixels;
}

- (void)testDetailedPreviewsRetainDistinctSamplingDetail {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    NSMutableSet<NSData *> *previews = [NSMutableSet set];
    for (NSString *style in @[@"detailed", @"oversampling_detailed_x2",
                              @"oversampling_detailed_x4", @"oversampling_detailed_x8"]) {
        NSData *pixels = [self previewPixelsForStyle:style theme:theme barDensity:1 barWidth:1 normalize:NO gainDB:0];
        XCTAssertGreaterThan(pixels.length, 0u);
        XCTAssertFalse([previews containsObject:pixels], @"%@ duplicates another style's preview", style);
        [previews addObject:pixels];
        XCTAssertEqualObjects(pixels,
                [self previewPixelsForStyle:style theme:theme barDensity:1 barWidth:1 normalize:NO gainDB:0]);
    }
}

- (void)testWaveformPreviewFollowsPaletteDensityAndLevels {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    NSData *plain = [self previewPixelsForStyle:@"basic" theme:theme barDensity:1 barWidth:1 normalize:NO gainDB:0];
    XCTAssertNotEqualObjects(plain,
            [self previewPixelsForStyle:@"basic" theme:theme barDensity:2 barWidth:1 normalize:NO gainDB:0]);
    XCTAssertNotEqualObjects(plain,
            [self previewPixelsForStyle:@"basic" theme:theme barDensity:1 barWidth:1 normalize:YES gainDB:0]);
    XCTAssertNotEqualObjects(plain,
            [self previewPixelsForStyle:@"basic" theme:theme barDensity:1 barWidth:1 normalize:NO gainDB:6]);
    theme.flatFill = YES;
    XCTAssertNotEqualObjects(plain,
            [self previewPixelsForStyle:@"basic" theme:theme barDensity:1 barWidth:1 normalize:NO gainDB:0]);
    WaveformTheme *orange = [WaveformTheme themeForIdentifier:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE
            isDark:YES artworkColor:nil customPlayed:nil customUnplayed:nil];
    XCTAssertNotEqualObjects(plain,
            [self previewPixelsForStyle:@"basic" theme:orange barDensity:1 barWidth:1 normalize:NO gainDB:0]);
}

// iOS's rule: until the user chooses, only the band styles draw the line.
- (void)testPlayheadLineIsTheBandStylesDefaultUntilChosen {
    for (NSString *style in WaveformRendererRegistry.availableIdentifiers) {
        XCTAssertEqual([WaveformRendererRegistry drawsPlayheadLineForIdentifier:style chosen:nil],
                       [style isEqualToString:@"three_band"] || [style isEqualToString:@"spectrum"], @"%@", style);
        XCTAssertTrue([WaveformRendererRegistry drawsPlayheadLineForIdentifier:style chosen:@YES], @"%@", style);
        XCTAssertFalse([WaveformRendererRegistry drawsPlayheadLineForIdentifier:style chosen:@NO], @"%@", style);
    }
    XCTAssertFalse([WaveformRendererRegistry drawsPlayheadLineForIdentifier:nil chosen:nil]);
}

// The preview's playhead sits at 40% of its 720 pixels. Under a playhead color
// the line spans the seek band there and nothing outside it, and the unplayed
// side is no longer dimmed.
- (void)testPreviewDrawsThePlayheadLineOverAWaveformPlayedThroughout {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    for (NSString *style in WaveformRendererRegistry.availableIdentifiers) {
        theme.playheadColor = nil;
        NSData *dimmed = [self previewPixelsForStyle:style theme:theme barDensity:1 barWidth:1 normalize:NO gainDB:0];
        theme.playheadColor = [VibeColor colorWithRed:1 green:0 blue:0 alpha:1];
        NSData *lined = [self previewPixelsForStyle:style theme:theme barDensity:1 barWidth:1 normalize:NO gainDB:0];
        XCTAssertEqual(lined.length, dimmed.length);
        const uint8_t *with = (const uint8_t *)lined.bytes;
        const uint8_t *without = (const uint8_t *)dimmed.bytes;
        size_t rowBytes = lined.length / 128;
        const uint8_t *onLine = with + 64 * rowBytes + 288 * 4;
        XCTAssertGreaterThan(onLine[0], 200, @"%@", style);
        XCTAssertLessThan(onLine[1], 60, @"%@", style);
        XCTAssertLessThan(onLine[2], 60, @"%@", style);
        XCTAssertEqual(onLine[3], 255, @"%@", style);
        // Above the band, where no style draws: the line stops with it.
        XCTAssertEqual((with + 2 * rowBytes + 288 * 4)[3], 0, @"%@", style);
        // The played side is untouched; the unplayed side differs somewhere.
        BOOL unplayedDiffers = NO;
        for (size_t row = 0; row < 128; row++) {
            XCTAssertEqual(memcmp(with + row * rowBytes, without + row * rowBytes, 280 * 4), 0,
                           @"%@ row %zu", style, row);
            unplayedDiffers |= memcmp(with + row * rowBytes + 300 * 4, without + row * rowBytes + 300 * 4,
                                      (720 - 300) * 4) != 0;
        }
        XCTAssertTrue(unplayedDiffers, @"%@", style);
    }
}

- (void)testCenteringChangesPreviewOnlyForSupportedStyles {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    for (NSString *style in WaveformRendererRegistry.availableIdentifiers) {
        NSData *centered = [self previewPixelsForStyle:style theme:theme barDensity:1 barWidth:1 normalize:NO gainDB:0];
        NSData *grounded = [self previewPixelsForStyle:style theme:theme barDensity:1 barWidth:1 centered:NO
                                             normalize:NO gainDB:0];
        XCTAssertEqual([centered isEqualToData:grounded],
                       ![WaveformRendererRegistry supportsCenteringForIdentifier:style], @"%@", style);
    }
    XCTAssertFalse([WaveformRendererRegistry supportsCenteringForIdentifier:@"sonic_cirrus"]);
    XCTAssertFalse([WaveformRendererRegistry supportsCenteringForIdentifier:@"cupertino_basic"]);
}

- (void)testGradientChangesPreviewOnlyForSupportedStyles {
    WaveformTheme *ramped = [WaveformTheme monochromeThemeIsDark:YES];
    WaveformTheme *flat = [WaveformTheme monochromeThemeIsDark:YES];
    flat.flatFill = YES;
    for (NSString *style in WaveformRendererRegistry.availableIdentifiers) {
        NSData *withRamp = [self previewPixelsForStyle:style theme:ramped barDensity:1 barWidth:1 normalize:NO
                                                gainDB:0];
        NSData *withoutRamp = [self previewPixelsForStyle:style theme:flat barDensity:1 barWidth:1 normalize:NO
                                                   gainDB:0];
        XCTAssertEqual([withRamp isEqualToData:withoutRamp],
                       ![WaveformRendererRegistry supportsGradientForIdentifier:style], @"%@", style);
    }
    XCTAssertFalse([WaveformRendererRegistry supportsGradientForIdentifier:@"spectrum"]);
    XCTAssertFalse([WaveformRendererRegistry supportsGradientForIdentifier:@"cupertino_basic"]);
}

// Grounded, each bar keeps its height and stands on the band's foot.
- (void)testGroundedBarsStandOnTheBaselineAtTheirCenteredHeight {
    // Quiet, so no style's centered bar reaches the band's foot already.
    auto waveform = VibeTestSteadyWaveform(1, {-0.3f, 0.5f, 0.01f});
    for (NSString *style in @[@"detailed", @"oversampling_detailed_x4", @"basic", @"cupertino"]) {
        CGRect boxes[2];
        for (BOOL centered : {YES, NO}) {
            WaveformRenderer *renderer = [self rendererForStyle:style];
            renderer.centered = centered;
            CALayer *host = renderer.parentLayer;
            [renderer updateWaveform:host.bounds progress:0.5 waveform:waveform.get()];
            [renderer settleMorphImmediately];
            boxes[centered] = VibeLitBounds(VibePictureOf(VibeMaskLayer(renderer)));
        }
        // A pixel apart at most: centered rounds both edges, grounded only its top.
        XCTAssertEqualWithAccuracy(boxes[NO].size.height, boxes[YES].size.height, 1, @"%@", style);
        XCTAssertEqualWithAccuracy(CGRectGetMinY(boxes[NO]), VibeBarBaseline(80), 0.5, @"%@", style);
        XCTAssertGreaterThan(CGRectGetMinY(boxes[YES]), CGRectGetMinY(boxes[NO]) + 5, @"%@", style);
    }
}

static CAGradientLayer *VibeFirstGradient(CALayer *layer) {
    if ([layer isKindOfClass:CAGradientLayer.class]) {
        return (CAGradientLayer *)layer;
    }
    NSMutableArray<CALayer *> *children = [NSMutableArray arrayWithArray:layer.sublayers ?: @[]];
    if (layer.mask) {
        [children addObject:layer.mask];
    }
    for (CALayer *child in children) {
        CAGradientLayer *found = VibeFirstGradient(child);
        if (found) {
            return found;
        }
    }
    return nil;
}

// Grounded, a bar's foot on the baseline reads the ramp where the midline did
// centered, so quiet passages keep their brightness: the band's ramp, 3-Band's
// side masks and Basic's full-view axis alike, re-aimed on each toggle.
- (void)testGroundedRampKeepsTheMidlinesBrightnessAtTheBaseline {
    CGFloat baseline = VibeBarBaseline(1);
    for (NSString *style in @[@"detailed", @"basic", @"three_band"]) {
        WaveformRenderer *renderer = [self rendererForStyle:style];
        CAGradientLayer *ramp = VibeFirstGradient(renderer.parentLayer);
        XCTAssertNotNil(ramp, @"%@", style);
        CGFloat (^at)(CGFloat) = ^CGFloat(CGFloat y) {
            return (y - ramp.startPoint.y) / (ramp.endPoint.y - ramp.startPoint.y);
        };
        CGFloat midline = at(0.5);
        renderer.centered = NO;
        XCTAssertEqualWithAccuracy(at(baseline), midline, 1e-6, @"%@", style);
        renderer.centered = YES;
        XCTAssertEqualWithAccuracy(at(0.5), midline, 1e-6, @"%@", style);
    }
}

- (void)testGroundedCupertinoTakesBasicsRamp {
    VibeColor *color = [VibeColor colorWithWhite:1 alpha:0.8];
    DetailedWaveformRenderer *cupertino = (DetailedWaveformRenderer *)[self rendererForStyle:@"cupertino"];
    DetailedWaveformRenderer *basic = (DetailedWaveformRenderer *)[self rendererForStyle:@"basic"];
    NSArray *mirrored = [cupertino gradientColorsForColor:color isDark:YES];
    cupertino.centered = NO;
    XCTAssertEqualObjects([cupertino gradientColorsForColor:color isDark:YES],
                          [basic gradientColorsForColor:color isDark:YES]);
    XCTAssertNotEqualObjects(mirrored, [basic gradientColorsForColor:color isDark:YES]);
}

- (void)testBarWidthChangesPreviewOnlyForSupportedStyles {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    for (NSString *style in WaveformRendererRegistry.availableIdentifiers) {
        NSData *plain = [self previewPixelsForStyle:style theme:theme barDensity:1 barWidth:1 normalize:NO gainDB:0];
        for (CGFloat width : {0.5, 2.0}) {
            NSData *changed = [self previewPixelsForStyle:style theme:theme barDensity:1 barWidth:width normalize:NO gainDB:0];
            XCTAssertEqual([plain isEqualToData:changed],
                    ![WaveformRendererRegistry supportsBarWidthForIdentifier:style], @"%@ width %g", style, width);
        }
    }
}

- (void)testPillWidthScalesHeightAndHoverWithinSeekBand {
    WaveformRenderer *renderer = [self rendererForStyle:@"cupertino_basic"];
    CALayer *host = renderer.parentLayer;
    CALayer *pill = host.sublayers.firstObject;
    CALayer *fill = pill.sublayers.firstObject;
    auto waveform = VibeTestSteadyWaveform(1, {});
    [renderer updateWaveform:host.bounds progress:0.25 waveform:waveform.get()];
    XCTAssertFalse([WaveformRendererRegistry supportsBarDensityForIdentifier:@"cupertino_basic"]);
    for (CGFloat scale : {0.5, 1.0, 2.0}) {
        [renderer setHoverHighlightX:-1];
        renderer.barWidthScale = scale;
        XCTAssertEqual(pill.bounds.size.height, 9 * scale);
        XCTAssertEqual(fill.bounds.size.height, pill.bounds.size.height);
        XCTAssertEqual(fill.bounds.size.width, 128);
        XCTAssertEqual(pill.cornerRadius, pill.bounds.size.height / 2);
        [renderer setHoverHighlightX:128];
        XCTAssertEqual(pill.bounds.size.height, 16 * scale);
        XCTAssertTrue(CGRectContainsRect([renderer seekHitBandForBounds:host.bounds], pill.frame));
    }
    renderer.barDensity = 0.5;
    [renderer updateWaveform:host.bounds progress:0.25 waveform:waveform.get()];
    XCTAssertEqual(pill.bounds.size.height, 32);
    host.bounds = CGRectMake(0, 0, 512, 20);
    [renderer updateWaveform:host.bounds progress:0.25 waveform:waveform.get()];
    XCTAssertTrue(CGRectContainsRect(host.bounds, pill.frame));
    [renderer updateWaveform:host.bounds progress:0 waveform:nullptr];
    renderer.barWidthScale = 0.5;
    XCTAssertTrue(pill.hidden);
}

// A lit column barely differs from Mono's played side. Over it, the column is
// a hole that shows the unplayed side.
- (void)testHoverOverThePlayedSideShowsTheUnplayedSide {
    auto waveform = VibeTestSteadyWaveform(1, {-0.5f, 0.5f, 0.25f});
    for (NSString *style in @[@"detailed", @"basic", @"cupertino", @"wiggle_centered", @"cupertino_basic"]) {
        WaveformRenderer *renderer = [self rendererForStyle:style];
        CALayer *host = renderer.parentLayer;
        [renderer updateWaveform:host.bounds progress:0.5 waveform:waveform.get()];
        NSArray<CALayer *> *layers = host.sublayers.firstObject.sublayers;
        CALayer *played = [style isEqualToString:@"cupertino_basic"] ? layers.firstObject : layers[1];
        CALayer *lit = layers.lastObject;

        [renderer setHoverHighlightX:100];
        XCTAssertTrue(lit.hidden, @"%@", style);
        CAShapeLayer *hole = (CAShapeLayer *)played.mask;
        XCTAssertNotNil(hole, @"%@", style);
        CGPoint inside = CGPointMake(CGRectGetMidX(lit.frame), CGRectGetMidY(lit.frame));
        XCTAssertFalse(CGPathContainsPoint(hole.path, NULL, inside, true), @"%@", style);
        XCTAssertTrue(CGPathContainsPoint(hole.path, NULL, CGPointMake(10, inside.y), true), @"%@", style);

        [renderer setHoverHighlightX:400];
        XCTAssertFalse(lit.hidden, @"%@", style);
        XCTAssertNil(played.mask, @"%@", style);

        // The playhead crosses the still cursor.
        [renderer updateProgress:0.9 waveform:waveform.get()];
        XCTAssertTrue(lit.hidden, @"%@", style);
        XCTAssertNotNil(played.mask, @"%@", style);

        [renderer setHoverHighlightX:-1];
        XCTAssertNil(played.mask, @"%@", style);
    }
}

- (void)testSonicCirrusHoverOverThePlayedSideTakesTheUnplayedColor {
    auto waveform = VibeTestSteadyWaveform(1, {-0.5f, 0.5f, 0.25f});
    WaveformRenderer *renderer = [self rendererForStyle:@"sonic_cirrus"];
    CALayer *host = renderer.parentLayer;
    [renderer updateWaveform:host.bounds progress:0.5 waveform:waveform.get()];
    NSArray<CALayer *> *bars = host.sublayers;
    XCTAssertEqual(bars.count, 256u);
    CGColorRef hover = renderer.theme.hoverColor.CGColor;
    CGColorRef unplayed = renderer.theme.unplayedColor.CGColor;

    // Bar 25 is played and bar 100 is not. Each bar's top is layer 2i.
    [renderer setHoverHighlightX:100];
    XCTAssertTrue(CGColorEqualToColor(bars[50].backgroundColor, unplayed));
    [renderer setHoverHighlightX:400];
    XCTAssertTrue(CGColorEqualToColor(bars[200].backgroundColor, hover));
    [renderer updateProgress:0.9 waveform:waveform.get()];
    XCTAssertTrue(CGColorEqualToColor(bars[200].backgroundColor, unplayed));
}

// Width changes only the thickness: a bar's coverage across its slot, two
// stems' strokes across a loop for Wiggle, or Sonic's layers.
- (void)testBarWidthRebuildsLiveGeometryWithoutChangingCount {
    auto waveform = VibeTestSteadyWaveform(1, {-0.5f, 0.5f, 0.25f});
    for (NSString *style in @[@"basic", @"cupertino", @"sonic_cirrus", @"wiggle_centered"]) {
        WaveformRenderer *renderer = [self rendererForStyle:style];
        CALayer *host = renderer.parentLayer;
        BOOL sonic = [style isEqualToString:@"sonic_cirrus"];
        BOOL wiggle = [style hasPrefix:@"wiggle"];
        DetailedWaveformRenderer *detailed = sonic ? nil : (DetailedWaveformRenderer *)renderer;
        for (CGFloat density : {0.5, 1.0, 2.0}) {
            renderer.barDensity = density;
            renderer.barWidthScale = 1;
            [renderer updateWaveform:host.bounds progress:0.5 waveform:waveform.get()];
            [renderer settleMorphImmediately];
            NSUInteger count = sonic ? host.sublayers.count / 2 : [detailed numBarsForWidth:512];
            XCTAssertEqual(count, (NSUInteger)((wiggle ? 64 : 128) * density));
            CGFloat pitch = 512.0 / count;
            CGFloat (^thickness)(void) = ^CGFloat {
                if (sonic) {
                    return host.sublayers.firstObject.bounds.size.width;
                }
                VibeTestPicture mask = VibePictureOf(VibeMaskLayer(renderer));
                if (wiggle) {
                    // Ten loops, at a row between the midline and the crests.
                    CGFloat loop = (512 - 1.5 * renderer.barWidthScale) / count;
                    return VibeLitWidth(mask, (size_t)(10 * loop), (size_t)(20 * loop), 25) / 20;
                }
                return VibeLitWidth(mask, (size_t)(10 * pitch), (size_t)(11 * pitch), 40);
            };
            CGFloat original = thickness();
            for (CGFloat width : {0.5, 2.0}) {
                renderer.barWidthScale = width;
                XCTAssertEqual(sonic ? host.sublayers.count / 2 : [detailed numBarsForWidth:512], count);
                XCTAssertEqualWithAccuracy(thickness(), MIN(original * width, pitch), wiggle ? 0.1 : 0.02,
                                           @"%@ density %g width %g", style, density, width);
            }
        }
    }
}

- (void)testNormalizationOnlyRaisesLevelsAndKeepsSilenceFinite {
    for (float rms : {0.0f, 0.000001f, 0.035f, 0.35f, 0.7f, 1.0f}) {
        auto waveform = VibeTestSteadyWaveform(1, {-rms, rms, rms * rms});
        float plain = VibeWaveformFullScaleRMSForWaveform(waveform.get(), NO);
        float normalized = VibeWaveformFullScaleRMSForWaveform(waveform.get(), YES);
        XCTAssertGreaterThan(normalized, 0);
        XCTAssertLessThanOrEqual(normalized, plain);
        if (rms == 0 || rms >= kVibeWaveformFullScaleRMS) XCTAssertEqual(normalized, plain);
        for (float gain : {-12.0f, 0.0f, 12.0f}) {
            for (float fraction : {0.0f, 0.1f, 0.5f, 1.0f}) {
                float energy = rms * rms * fraction;
                float level = VibeWaveformBarLevel(energy, normalized, gain);
                XCTAssertTrue(std::isfinite(level));
                XCTAssertGreaterThanOrEqual(level, VibeWaveformBarLevel(energy, plain, gain));
            }
        }
    }
}

// Normalize only raises. A Detailed type's reference is its own energy
// grid's, which a zoom step fixes, so its tallest column reaches full height;
// the bar styles' is the track's loudest 1/1024, which coarser bars never
// pass.
- (void)testEveryDetailedVariantNormalizesAgainstTheTracksOwnReference {
    std::vector<VibeTestBin> bins(8192, {-0.1f, 0.1f, 0.01f});
    bins[4095] = {-0.8f, 0.8f, 0.64f}; // a transient inside a quieter averaged section
    auto waveform = VibeTestWaveform(bins);
    for (NSString *identifier in [WaveformRendererRegistry availableIdentifiers]) {
        // These two draw individual layers; the next test covers their geometry.
        // The band styles draw three levels a bar, which their own tests cover.
        if ([identifier isEqualToString:@"sonic_cirrus"] || [identifier isEqualToString:@"cupertino_basic"] ||
            [WaveformRendererRegistry readsBandsForIdentifier:identifier]) continue;
        DetailedWaveformRenderer *renderer = (DetailedWaveformRenderer *)[self rendererForStyle:identifier];
        XCTAssertTrue([renderer isKindOfClass:DetailedWaveformRenderer.class], @"%@", identifier);
        double perPoint = [renderer columnsPerPoint];
        for (CGFloat width : {257.0, 512.0, 773.0}) {
            NSUInteger count = perPoint > 0 ? (NSUInteger)llround(width * perPoint) : [renderer numBarsForWidth:width];
            double frames = (double)waveform->totalFrames() / (double)count;
            std::vector<float> plain(count * 2), normalized(count * 2);
            for (float gain : {-12.0f, 0.0f, 12.0f}) {
                renderer.gainDB = gain;
                renderer.normalizesLevels = NO;
                [renderer fillColumns:plain.data() framesPerColumn:frames first:0 count:count waveform:waveform.get()];
                renderer.normalizesLevels = YES;
                [renderer fillColumns:normalized.data() framesPerColumn:frames first:0 count:count
                             waveform:waveform.get()];
                for (NSUInteger i = 0; i < count; i++) {
                    XCTAssertLessThanOrEqual(normalized[i * 2], plain[i * 2] + 1e-6, @"%@", identifier);
                    XCTAssertGreaterThanOrEqual(normalized[i * 2 + 1], plain[i * 2 + 1] - 1e-6, @"%@", identifier);
                }
                if (gain == 0) {
                    float tallest = *std::max_element(normalized.begin(), normalized.end());
                    XCTAssertLessThanOrEqual(tallest, 1 + 1e-6, @"%@", identifier);
                    if (perPoint > 0) {
                        XCTAssertGreaterThan(tallest, 0.9, @"%@ width %g", identifier, width);
                    }
                }
            }
        }
    }
}

// Detailed's columns at a width, read as the view reads them, at one point a
// pixel.
static std::vector<float> VibeDetailedColumns(DetailedWaveformRenderer *renderer, AudioWaveform *waveform,
                                              CGFloat width) {
    NSUInteger count = (NSUInteger)llround(width * [renderer columnsPerPoint]);
    std::vector<float> envelope(count * 2);
    [renderer fillColumns:envelope.data() framesPerColumn:(double)waveform->totalFrames() / (double)count first:0
                    count:count waveform:waveform];
    return envelope;
}

// Columns finer than the energy grid need not cover a transient its energy
// holds. The quiet columns beside it must still draw quiet.
- (void)testDetailedQuietBarsBesideATransientStayQuiet {
    std::vector<VibeTestBin> bins(8192, {-0.01f, 0.01f, 0.0001f});
    bins[816] = {-0.5f, 0.5f, 0.25f};
    auto waveform = VibeTestWaveform(bins);
    DetailedWaveformRenderer *renderer = (DetailedWaveformRenderer *)[self rendererForStyle:@"detailed"];
    for (CGFloat width : {930.0, 931.0, 1200.0}) {
        std::vector<float> envelope = VibeDetailedColumns(renderer, waveform.get(), width);
        NSUInteger count = envelope.size() / 2;
        XCTAssertGreaterThan(count, kVibeWaveformEnergyColumns);
        for (NSUInteger i = 0; i < count; i++) {
            if (VibeTestColumn(waveform.get(), i, count).hi < 0.1f) {
                XCTAssertLessThan(envelope[i * 2 + 1], 0.05f, @"width %g bar %lu", width, i);
            }
        }
    }
}

// A transient changes only the columns that hold it or read its energy
// column, which are those whose centers lie within one energy column of it.
- (void)testDetailedBarsBesideAStraddlingTransientKeepTheirHeight {
    std::vector<VibeTestBin> steady(8192, {-0.1f, 0.1f, 0.01f}), bins = steady;
    bins[816] = {-0.9f, 0.9f, 0.81f};
    auto waveform = VibeTestWaveform(bins), background = VibeTestWaveform(steady);
    DetailedWaveformRenderer *renderer = (DetailedWaveformRenderer *)[self rendererForStyle:@"detailed"];
    for (CGFloat width : {930.0, 931.0, 1200.0}) {
        std::vector<float> envelope = VibeDetailedColumns(renderer, waveform.get(), width);
        std::vector<float> plain = VibeDetailedColumns(renderer, background.get(), width);
        NSUInteger count = envelope.size() / 2;
        double frames = 8192.0 / count;
        // Four pixels of columns at one column a pixel and two a point.
        double energyFrames = frames * 4 * [renderer columnsPerPoint];
        double transientColumn = floor(816 / energyFrames);
        NSUInteger untouched = 0;
        for (NSUInteger i = 0; i < count; i++) {
            double u = (i + 0.5) * frames / energyFrames - 0.5;
            BOOL reads = floor(u) == transientColumn || floor(u) + 1 == transientColumn;
            if (!reads && VibeTestColumn(waveform.get(), i, count).hi < 0.5f) {
                XCTAssertEqualWithAccuracy(envelope[i * 2 + 1], plain[i * 2 + 1], 1e-3, @"width %g bar %lu", width, i);
                untouched++;
            }
        }
        XCTAssertGreaterThan(untouched, count * 9 / 10);
    }
}

// Normalize only raises, at every width.
- (void)testLayerStylesOnlyGrowUnderNormalization {
    std::vector<VibeTestBin> bins(1024, {-0.1f, 0.1f, 0.01f});
    bins[511] = {-0.5f, 0.5f, 0.1f};
    auto waveform = VibeTestWaveform(bins);
    for (NSString *identifier in @[@"sonic_cirrus", @"cupertino_basic"]) {
        WaveformRenderer *renderer = [self rendererForStyle:identifier];
        CALayer *host = renderer.parentLayer;
        for (CGFloat width : {257.0, 512.0, 773.0}) {
            host.bounds = CGRectMake(0, 0, width, 80);
            for (float gain : {-12.0f, 0.0f, 12.0f}) {
                renderer.gainDB = gain;
                renderer.normalizesLevels = NO;
                [renderer updateWaveform:host.bounds progress:0.5 waveform:waveform.get()];
                [renderer settleMorphImmediately];
                std::vector<CGFloat> plain;
                for (CALayer *layer in host.sublayers) plain.push_back(layer.bounds.size.height);
                renderer.normalizesLevels = YES;
                [renderer updateWaveform:host.bounds progress:0.5 waveform:waveform.get()];
                [renderer settleMorphImmediately];
                XCTAssertEqual(host.sublayers.count, plain.size());
                CGFloat maximum = 0;
                for (NSUInteger i = 0; i < plain.size(); i++) {
                    CGFloat height = host.sublayers[i].bounds.size.height;
                    XCTAssertGreaterThanOrEqual(height, plain[i], @"%@", identifier);
                    maximum = MAX(maximum, height);
                }
                if (gain == 0) {
                    // Sonic's full-height top bar is 42pt in this 80pt band;
                    // Progress is a fixed 9pt pill independent of audio.
                    if ([identifier isEqualToString:@"sonic_cirrus"]) {
                        XCTAssertLessThanOrEqual(maximum, 42 + 1e-6);
                    } else {
                        XCTAssertEqualWithAccuracy(maximum, 9, 1e-6);
                    }
                }
            }
        }
    }
}

- (void)testWaveformRegistryBuildsDistinctStylesThatShareAClass {
    NSArray *identifiers = [WaveformRendererRegistry availableIdentifiers];
    XCTAssertFalse([identifiers containsObject:SETTINGS_VALUE_WAVEFORM_STYLE_LEGACY_WIGGLE_MC]);
    XCTAssertTrue([identifiers containsObject:SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE]);
    XCTAssertEqualObjects([WaveformRendererRegistry displayNameForIdentifier:@"wiggle_centered"], STR_WAVEFORM_STYLE_WIGGLE);
    XCTAssertEqualObjects([WaveformRendererRegistry displayNameForIdentifier:@"spectrum"], STR_WAVEFORM_STYLE_SPECTRUM);
    XCTAssertEqual([self rendererForStyle:@"spectrum"].class, SpectrumWaveformRenderer.class);
    XCTAssertEqualObjects([WaveformRendererRegistry resolveStyleIdentifier:@"missing-style"], SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT);
    XCTAssertEqualObjects([WaveformRendererRegistry resolveStyleIdentifier:nil], SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT);
    DetailedWaveformRenderer *detailed = (DetailedWaveformRenderer *)[self rendererForStyle:@"detailed"];
    DetailedWaveformRenderer *wiggle = (DetailedWaveformRenderer *)[self rendererForStyle:@"wiggle_centered"];
    XCTAssertEqual(detailed.class, DetailedWaveformRenderer.class);
    XCTAssertEqual(wiggle.class, DetailedWaveformRenderer.class);
    XCTAssertEqual([detailed columnsPerPoint], 2);
    XCTAssertEqual([wiggle columnsPerPoint], 0, @"Wiggle draws loops, not a step's columns");
    XCTAssertEqual([wiggle numBarsForWidth:512], 64u);
    wiggle.samplingWidth = 512;
    XCTAssertEqual([wiggle numBarsForWidth:2048], 64u, @"Zoom must preserve Wiggle's loops");
    wiggle.samplingWidth = 768;
    XCTAssertEqual([wiggle numBarsForWidth:2048], 96u);
}

// The Detailed family is one style whose Type picks its identifier, so the
// choosers list it once and keep each persisted identifier.
- (void)testDetailedTypesAreOneStyleInTheChoosers {
    NSArray<NSString *> *types = @[@"detailed", @"oversampling_detailed_x2",
                                   @"oversampling_detailed_x4", @"oversampling_detailed_x8"];
    NSArray<NSString *> *styles = WaveformRendererRegistry.styleIdentifiers;
    XCTAssertEqual(styles.count, WaveformRendererRegistry.availableIdentifiers.count - types.count + 1);
    NSMutableSet<NSString *> *listedTypes = [NSMutableSet setWithArray:styles];
    [listedTypes intersectSet:[NSSet setWithArray:types]];
    XCTAssertEqualObjects(listedTypes, [NSSet setWithObject:@"oversampling_detailed_x4"]);
    NSMutableSet<NSString *> *typeNames = [NSMutableSet set];
    for (NSString *type in types) {
        XCTAssertEqualObjects([WaveformRendererRegistry typeIdentifiersForIdentifier:type], types);
        XCTAssertEqualObjects([WaveformRendererRegistry styleIdentifierForIdentifier:type], @"oversampling_detailed_x4");
        XCTAssertEqualObjects([WaveformRendererRegistry displayNameForIdentifier:type], STR_WAVEFORM_STYLE_DETAILED);
        [typeNames addObject:[WaveformRendererRegistry typeDisplayNameForIdentifier:type]];
    }
    XCTAssertEqual(typeNames.count, types.count);
    XCTAssertEqualObjects([WaveformRendererRegistry typeIdentifiersForIdentifier:@"basic"], @[]);
    XCTAssertEqualObjects([WaveformRendererRegistry styleIdentifierForIdentifier:@"basic"], @"basic");
    // NSPopUpButton drops an item whose title repeats another's.
    NSMutableSet<NSString *> *styleNames = [NSMutableSet set];
    for (NSString *style in styles) {
        [styleNames addObject:[WaveformRendererRegistry displayNameForIdentifier:style]];
    }
    XCTAssertEqual(styleNames.count, styles.count);
}

- (void)testWiggleHighlightsWholeLoopsWithoutQuantizingThePlayedFill {
    DetailedWaveformRenderer *renderer = (DetailedWaveformRenderer *)[self rendererForStyle:@"wiggle_centered"];
    CALayer *host = renderer.parentLayer;
    CGRect leftStem = [renderer hoverColumnRectForX:2 bounds:host.bounds scale:2];
    CGRect crest = [renderer hoverColumnRectForX:4 bounds:host.bounds scale:2];
    CGRect rightStem = [renderer hoverColumnRectForX:6 bounds:host.bounds scale:2];
    XCTAssertTrue(CGRectEqualToRect(leftStem, crest));
    XCTAssertTrue(CGRectEqualToRect(leftStem, rightStem));
    XCTAssertGreaterThanOrEqual(leftStem.size.width, 8);
    XCTAssertGreaterThan([renderer hoverColumnRectForX:10 bounds:host.bounds scale:2].origin.x, leftStem.origin.x);
    XCTAssertEqualWithAccuracy([renderer playedClipWidthForProgress:0.137 width:512], 0.137 * 512, 1e-6);
}

- (void)testWiggleCollapseFadesTheBaselineButKeepsLoadedQuietAudioVisible {
    auto waveform = VibeTestSteadyWaveform(1, {-0.014f, 0.014f, 0.000196f});
    for (BOOL centered : {YES, NO}) {
        WaveformRenderer *renderer = [self rendererForStyle:@"wiggle_centered"];
        renderer.centered = centered;
        CALayer *host = renderer.parentLayer;
        [renderer updateWaveform:host.bounds progress:0 waveform:waveform.get()];
        [renderer settleMorphImmediately];
        CALayer *mask = VibeMaskLayer(renderer);
        XCTAssertEqual(mask.opacity, 1);
        [renderer updateWaveform:host.bounds progress:0 waveform:nullptr];
        [renderer backingScaleDidChange]; // redraw the displayed samples without advancing a timer
        XCTAssertGreaterThan(mask.opacity, 0);
        XCTAssertLessThan(mask.opacity, 1);
        [renderer settleMorphImmediately];
        XCTAssertEqual(mask.opacity, 0);
    }
}

- (void)testSettledResizeDrawsOnceWithoutStartingAnAnimation {
    __block NSUInteger rebuilds = 0, fills = 0;
    WaveformMorphEngine *morph = [[WaveformMorphEngine alloc]
            initWithVScale:^CGFloat(CGFloat height) { return height; }
            rebuild:^{ rebuilds++; }];
    void (^fill)(std::vector<float> &) = ^(std::vector<float> &samples) {
        fills++;
        for (NSUInteger i = 0; i < samples.size(); i++) samples[i] = (float)(i + 1) / samples.size();
    };
    [morph updateTargetForSize:CGSizeMake(600, 80) identity:(__bridge const void *)self count:60 fill:fill];
    [morph settleImmediately];
    rebuilds = fills = 0;
    for (NSUInteger count = 61; count <= 100; count++) {
        [morph updateTargetForSize:CGSizeMake(count * 10, 80) identity:(__bridge const void *)self count:count fill:fill];
        XCTAssertTrue(morph.isSettled);
        XCTAssertEqual([morph displayedSamples].size(), count);
        XCTAssertEqualWithAccuracy([morph displayedSamples][0], 1.0f / count, 1e-6);
        XCTAssertEqual([morph displayedSamples].back(), 1.0f);
    }
    XCTAssertEqual(rebuilds, 40u);
    XCTAssertEqual(fills, 40u);
    [morph updateTargetForSize:CGSizeMake(1000, 90) identity:(__bridge const void *)self count:100 fill:fill];
    XCTAssertEqual(rebuilds, 41u);
    XCTAssertEqual(fills, 40u, @"Height alone must not reread the waveform");
    [morph updateTargetForSize:CGSizeMake(1000, 90) identity:(__bridge const void *)self count:100 fill:fill];
    XCTAssertEqual(rebuilds, 41u, @"An unchanged draw must do no work");
}

- (void)testResizePreservesAGainMorphAndItsPairedSamples {
    WaveformMorphEngine *morph = [[WaveformMorphEngine alloc]
            initWithVScale:^CGFloat(CGFloat height) { return height; } rebuild:^{}];
    morph.samplesPerBar = 2;
    [morph updateTargetForSize:CGSizeMake(600, 80) identity:(__bridge const void *)self count:4
                         fill:^(std::vector<float> &samples) { samples = {-0.2f, 0.4f, -0.6f, 0.8f}; }];
    XCTAssertFalse(morph.isSettled, @"New audio still grows into view");
    [morph settleImmediately];
    [morph invalidateTarget];
    [morph updateTargetForSize:CGSizeMake(600, 80) identity:(__bridge const void *)self count:4
                         fill:^(std::vector<float> &samples) { samples = {-0.1f, 0.2f, -0.3f, 0.4f}; }];
    XCTAssertFalse(morph.isSettled, @"Gain still eases with an unchanged waveform identity");
    [morph updateTargetForSize:CGSizeMake(900, 80) identity:(__bridge const void *)self count:8
                         fill:^(std::vector<float> &samples) { samples.assign(8, 0.1f); }];
    XCTAssertFalse(morph.isSettled);
    const std::vector<float> carried = {-0.2f, 0.4f, -0.2f, 0.4f, -0.6f, 0.8f, -0.6f, 0.8f};
    XCTAssertTrue([morph displayedSamples] == carried);
    [morph settleImmediately];
    XCTAssertTrue([morph displayedSamples] == std::vector<float>(8, 0.1f));
    [morph dipDisplayedSamplesFromFraction:0 toFraction:0.25];
    XCTAssertFalse(morph.isSettled, @"The conversion sweep still animates");
    [morph settleImmediately];
}

- (void)testSilentWaveformAndEmptyStateRemainDistinctAfterResize {
    __block NSUInteger rebuilds = 0;
    WaveformMorphEngine *morph = [[WaveformMorphEngine alloc]
            initWithVScale:^CGFloat(CGFloat height) { return height; }
            rebuild:^{ rebuilds++; }];
    void (^silence)(std::vector<float> &) = ^(std::vector<float> &samples) {
        std::fill(samples.begin(), samples.end(), 0.0f);
    };
    [morph updateTargetForSize:CGSizeMake(600, 80) identity:(__bridge const void *)self count:60 fill:silence];
    [morph settleImmediately];
    [morph updateTargetForSize:CGSizeMake(900, 80) identity:(__bridge const void *)self count:90 fill:silence];
    XCTAssertTrue(morph.isSettled);
    XCTAssertEqual(morph.barMinHeight, 1);
    rebuilds = 0;
    [morph updateTargetForSize:CGSizeMake(900, 80) identity:NULL count:90 fill:silence];
    XCTAssertEqual(morph.barMinHeight, 0);
    XCTAssertEqual(rebuilds, 1u);
}

// A quiet intro decoded ahead of a louder passage must not draw at full height
// and then shrink: a streaming load holds the fixed reference, and so does
// every snapshot of it.
- (void)testNormalizationWaitsForTheWholeTrack {
    auto snapshot = VibeTestSteadyWaveform(8192, {-0.1f, 0.1f, 0.01f}, false);
    XCTAssertFalse(snapshot->isComplete());
    XCTAssertEqual(VibeWaveformFullScaleRMSForWaveform(snapshot.get(), YES), kVibeWaveformFullScaleRMS);

    auto whole = VibeTestSteadyWaveform(8192, {-0.1f, 0.1f, 0.01f});
    XCTAssertTrue(whole->isComplete());
    XCTAssertEqualWithAccuracy(VibeWaveformFullScaleRMSForWaveform(whole.get(), YES), 0.1f, 1e-6);
}

#pragma mark - Stability

// Stationary noise, 64 frames a bin: no rhythm, so any change a resize makes
// beyond the content's own stretch is the renderer's.
static std::unique_ptr<AudioWaveform> VibeNoiseWaveform(bool bands) {
    std::mt19937 rng(11);
    std::uniform_real_distribution<float> peak(0.2f, 0.9f);
    std::vector<VibeTestBin> bins(65536);
    std::vector<std::array<float, 3>> bandLevels;
    for (VibeTestBin &bin : bins) {
        float level = peak(rng);
        bin = {-level * peak(rng), level, level * level * 0.25f};
        if (bands) {
            bandLevels.push_back({bin.meanSquare * 0.7f, bin.meanSquare * 0.2f * peak(rng), bin.meanSquare * 0.1f});
        }
    }
    return VibeTestWaveform(bins, bandLevels, true, 64);
}

// A picture's ink per pixel column, the alpha it lays down.
static std::vector<double> VibeColumnInk(const VibeTestPicture &picture) {
    std::vector<double> ink(picture.width, 0);
    for (size_t row = 0; row < picture.height; row++) {
        for (size_t x = 0; x < picture.width; x++) ink[x] += picture.alpha(x, row) / 255.0;
    }
    return ink;
}

// The mean change of the ink from each width to the next, on a common time
// axis, as a share of the mean ink. One point a step, at 2x, as a live
// resize goes.
- (double)resizeChangeForStyle:(NSString *)style picture:(VibeTestPicture (^)(WaveformRenderer *))picture {
    auto waveform = VibeNoiseWaveform([WaveformRendererRegistry readsBandsForIdentifier:style]);
    WaveformRenderer *renderer = [self rendererForStyle:style];
    renderer.parentLayer.contentsScale = 2;
    const int samples = 4096;
    std::vector<std::vector<double>> axes;
    double meanInk = 0;
    for (CGFloat width = 700; width <= 720; width += 1) {
        CGRect bounds = CGRectMake(0, 0, width, 60);
        renderer.parentLayer.bounds = bounds;
        [renderer updateWaveform:bounds progress:1 waveform:waveform.get()];
        [renderer settleMorphImmediately];
        std::vector<double> ink = VibeColumnInk(picture(renderer));
        std::vector<double> axis(samples);
        for (int j = 0; j < samples; j++) {
            double u = (j + 0.5) / samples * ink.size() - 0.5;
            size_t left = (size_t)std::clamp(std::floor(u), 0.0, (double)ink.size() - 1);
            size_t right = std::min(left + 1, ink.size() - 1);
            double t = std::clamp(u - (double)left, 0.0, 1.0);
            axis[(size_t)j] = ink[left] * (1 - t) + ink[right] * t;
            meanInk += axis[(size_t)j];
        }
        axes.push_back(axis);
    }
    meanInk /= (double)(axes.size() * samples);
    double change = 0;
    for (size_t w = 0; w + 1 < axes.size(); w++) {
        for (int j = 0; j < samples; j++) change += std::fabs(axes[w][(size_t)j] - axes[w + 1][(size_t)j]);
    }
    return change / (double)((axes.size() - 1) * samples) / meanInk;
}

// What the zoom steps are for: a resize moves little ink. Before them,
// Detailed moved about 0.024 of it a step, through a comb that slid with the
// width, and Normalize's reference breathed with the bar count. Each ceiling
// is about 1.6 times what the style moves now.
- (void)testAResizeMovesLittleInk {
    VibeTestPicture (^mask)(WaveformRenderer *) = ^VibeTestPicture(WaveformRenderer *renderer) {
        return VibePictureOf(VibeMaskLayer(renderer));
    };
    VibeTestPicture (^bands)(WaveformRenderer *) = ^VibeTestPicture(WaveformRenderer *renderer) {
        return VibePictureOf(renderer.parentLayer.sublayers.firstObject.sublayers.firstObject.sublayers.firstObject);
    };
    NSDictionary<NSString *, NSNumber *> *ceilings = @{@"detailed": @0.008, @"oversampling_detailed_x4": @0.02,
                                                       @"three_band": @0.001};
    for (NSString *style in ceilings) {
        double change = [self resizeChangeForStyle:style picture:[style isEqualToString:@"three_band"] ? bands : mask];
        XCTAssertGreaterThan(change, 0, @"%@ drew nothing", style);
        XCTAssertLessThan(change, ceilings[style].doubleValue, @"%@", style);
    }
}

#pragma mark - 3-Band

// The painter's layers, in order: low, mid, high, low+mid, low+high, mid+high,
// all three.
static const NSUInteger kThreeBandLayers = 7;

// 1,024 identical bins with these band mean squares, under a broadband RMS
// of 0.1.
static std::unique_ptr<AudioWaveform> VibeThreeBandTestWaveform(std::array<float, 3> bands) {
    return VibeTestWaveform(std::vector<VibeTestBin>(1024, {-0.1f, 0.1f, 0.01f}),
                            std::vector<std::array<float, 3>>(1024, bands));
}

// The band layers' host, which the sides' mask covers; its one sublayer is
// the picture.
static CALayer *VibeThreeBandHost(WaveformRenderer *renderer) {
    return renderer.parentLayer.sublayers.firstObject.sublayers.firstObject;
}

static VibeTestPicture VibeThreeBandPicture(WaveformRenderer *renderer) {
    return VibePictureOf(VibeThreeBandHost(renderer).sublayers.firstObject);
}

static CGFloat VibeAlphaOf(id color) {
    return CGColorGetAlpha((__bridge CGColorRef)color);
}

// A theme whose layers are told apart by their green: layer i is 30 * (i + 1).
static WaveformTheme *VibeNumberedBandTheme(void) {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    theme.flatFill = YES;
    NSMutableArray<VibeColor *> *bands = [NSMutableArray array];
    for (NSUInteger layer = 0; layer < kThreeBandLayers; layer++) {
        [bands addObject:[NSColor colorWithSRGBRed:0 green:(layer + 1) * 30 / 255.0 blue:0 alpha:1]];
    }
    theme.bandColors = bands;
    return theme;
}

- (VibeTestPicture)threeBandPictureForBands:(std::array<float, 3>)bands normalize:(BOOL)normalize
                                   centered:(BOOL)centered waveform:(BOOL)hasWaveform {
    auto waveform = VibeThreeBandTestWaveform(bands);
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    renderer.theme = VibeNumberedBandTheme();
    [renderer updateColors:YES];
    renderer.normalizesLevels = normalize;
    renderer.centered = centered;
    CALayer *host = renderer.parentLayer;
    [renderer updateWaveform:host.bounds progress:0.5 waveform:hasWaveform ? waveform.get() : nullptr];
    [renderer settleMorphImmediately];
    return VibeThreeBandPicture(renderer);
}

// What shows of each layer down the center column: the rows from its top to
// its bottom, in pixels, 0 where it shows nowhere. A layer no taller than one
// painted after it is covered.
static std::vector<CGFloat> VibeVisibleLayerHeights(const VibeTestPicture &picture) {
    std::vector<CGFloat> heights(kThreeBandLayers, 0);
    size_t x = picture.width / 2;
    for (NSUInteger layer = 0; layer < kThreeBandLayers; layer++) {
        uint32_t color = (uint32_t)((layer + 1) * 30) << 8;
        size_t top = SIZE_MAX, bottom = 0;
        for (size_t row = 0; row < picture.height; row++) {
            if (picture.alpha(x, row) == 255 && picture.rgb(x, row) == color) {
                top = MIN(top, row);
                bottom = MAX(bottom, row);
            }
        }
        heights[layer] = top == SIZE_MAX ? 0 : (CGFloat)(bottom - top + 1);
    }
    return heights;
}

- (std::vector<CGFloat>)visibleThreeBandLayerHeightsForBands:(std::array<float, 3>)bands {
    return VibeVisibleLayerHeights([self threeBandPictureForBands:bands normalize:NO centered:YES waveform:YES]);
}

// Grounded, every band set stands on the baseline at its centered height, so
// the rings still nest.
- (void)testGroundedThreeBandStandsOnTheBaseline {
    std::array<float, 3> bands = {1, 0.01f, 0.0001f};
    VibeTestPicture centered = [self threeBandPictureForBands:bands normalize:NO centered:YES waveform:YES];
    VibeTestPicture grounded = [self threeBandPictureForBands:bands normalize:NO centered:NO waveform:YES];
    CGRect up = VibeLitBounds(centered, 128), down = VibeLitBounds(grounded, 128);
    XCTAssertEqualWithAccuracy(down.size.height, up.size.height, 1);
    XCTAssertEqualWithAccuracy(CGRectGetMinY(down), VibeBarBaseline(80), 1);
    // Every visible ring's top stands where its whole height reaches.
    std::vector<CGFloat> heights = VibeVisibleLayerHeights(centered);
    size_t x = grounded.width / 2;
    for (NSUInteger layer = 0; layer < kThreeBandLayers; layer++) {
        if (heights[layer] == 0) continue;
        uint32_t color = (uint32_t)((layer + 1) * 30) << 8;
        size_t top = SIZE_MAX;
        for (size_t row = 0; row < grounded.height && top == SIZE_MAX; row++) {
            if (grounded.alpha(x, row) == 255 && grounded.rgb(x, row) == color) top = row;
        }
        XCTAssertNotEqual(top, SIZE_MAX, @"layer %lu", layer);
        CGFloat height = (CGFloat)grounded.height - top - VibeBarBaseline(80);
        XCTAssertEqualWithAccuracy(height, heights[layer], 1.5, @"layer %lu", layer);
    }
}

// Which layers show: each band alone in its own color, and every ring
// colored by the set of bands reaching it, so the rings nest as the sets do.
- (void)testThreeBandRingsAreTheSetsOfBandsReachingThem {
    std::vector<CGFloat> low = [self visibleThreeBandLayerHeightsForBands:{1, 0, 0}];
    std::vector<CGFloat> mid = [self visibleThreeBandLayerHeightsForBands:{0, 1, 0}];
    std::vector<CGFloat> high = [self visibleThreeBandLayerHeightsForBands:{0, 0, 1}];
    for (NSUInteger layer = 0; layer < kThreeBandLayers; layer++) {
        XCTAssertEqual(low[layer] > 0, layer == 0, @"layer %lu", layer);
        XCTAssertEqual(mid[layer] > 0, layer == 1, @"layer %lu", layer);
        XCTAssertEqual(high[layer] > 0, layer == 2, @"layer %lu", layer);
    }

    // A loud low, a mid and a faint high: the low band out to the low, low
    // and mid out to the mid, the all-bands core out to the high.
    std::vector<CGFloat> nested = [self visibleThreeBandLayerHeightsForBands:{1, 0.01f, 0.0001f}];
    XCTAssertGreaterThan(nested[0], nested[3]);
    XCTAssertGreaterThan(nested[3], nested[6]);
    XCTAssertGreaterThan(nested[6], 0);
    XCTAssertEqual(nested[1] + nested[2] + nested[4] + nested[5], 0);

    // The same, led by the high band: high, then mid and high, then the core.
    std::vector<CGFloat> bright = [self visibleThreeBandLayerHeightsForBands:{0.0001f, 0.01f, 1}];
    XCTAssertGreaterThan(bright[2], bright[5]);
    XCTAssertGreaterThan(bright[5], bright[6]);
    XCTAssertEqual(bright[0] + bright[1] + bright[3] + bright[4], 0);
}

// A point's hairline in the all-bands color, which at 1x straddles two rows.
- (void)testThreeBandSilenceIsAHairlineAndNoWaveformIsNothing {
    VibeTestPicture silence = [self threeBandPictureForBands:{0, 0, 0} normalize:NO centered:YES waveform:YES];
    size_t x = silence.width / 2;
    CGFloat coverage = 0;
    for (size_t row = 0; row < silence.height; row++) {
        CGFloat alpha = silence.alpha(x, row) / 255.0;
        if (alpha > 0) {
            coverage += alpha;
            XCTAssertEqualWithAccuracy((silence.rgb(x, row) >> 8 & 0xff) / alpha, 7 * 30, 2, @"the core's green");
            XCTAssertEqual(silence.rgb(x, row) & 0xff00ff, 0u);
        }
    }
    XCTAssertEqualWithAccuracy(coverage, 1, 0.02);
    VibeTestPicture empty = [self threeBandPictureForBands:{0, 0, 0} normalize:NO centered:YES waveform:NO];
    XCTAssertTrue(CGRectIsNull(VibeLitBounds(empty)), @"no waveform draws nothing");
}

// Under Normalize, the tallest band against its share reaches full height,
// whichever band it is; a band already past full stays where it was.
- (void)testThreeBandNormalizeFillsTheTallestBand {
    CGFloat full = 2 * VibeBarVScale(80);
    std::vector<CGFloat> lowLed = VibeVisibleLayerHeights(
            [self threeBandPictureForBands:{0.001f, 0.0001f, 0.00001f} normalize:YES centered:YES waveform:YES]);
    XCTAssertEqualWithAccuracy(lowLed[0], full, 1);
    std::vector<CGFloat> highLed = VibeVisibleLayerHeights(
            [self threeBandPictureForBands:{0.00001f, 0.00001f, 0.001f} normalize:YES centered:YES waveform:YES]);
    XCTAssertEqualWithAccuracy(highLed[2], full, 1);
    std::array<float, 3> loud = {1, 0.01f, 0.0001f};
    XCTAssertTrue([self threeBandPictureForBands:loud normalize:YES centered:YES waveform:YES].pixels ==
                  [self threeBandPictureForBands:loud normalize:NO centered:YES waveform:YES].pixels);
}

// A renderer reused across widths and tracks draws what a fresh one draws:
// no reference outlives the waveform or the width it was read for.
- (void)testBandNormalizationStaysCurrentAcrossResizeAndTrackChanges {
    auto quiet = VibeThreeBandTestWaveform({0.001f, 0.0001f, 0.00001f});
    auto loud = VibeThreeBandTestWaveform({0.1f, 0.01f, 0.001f});
    auto partial = VibeTestWaveform(std::vector<VibeTestBin>(512, {-0.1f, 0.1f, 0.01f}),
                                    std::vector<std::array<float, 3>>(512, {0.01f, 0.001f, 0.0001f}), false);
    for (NSString *style in @[@"three_band", @"spectrum"]) {
        WaveformRenderer *reused = [self rendererForStyle:style];
        reused.normalizesLevels = YES;
        for (AudioWaveform *waveform : {quiet.get(), loud.get(), partial.get(), quiet.get()}) {
            for (CGFloat width : {3000.0, 300.0, 1024.0, 2500.0}) {
                CGRect bounds = CGRectMake(0, 0, width, 80);
                reused.parentLayer.bounds = bounds;
                [reused updateWaveform:bounds progress:0.4 waveform:waveform];
                [reused settleMorphImmediately];
                WaveformRenderer *fresh = [self rendererForStyle:style];
                fresh.normalizesLevels = YES;
                fresh.parentLayer.bounds = bounds;
                [fresh updateWaveform:bounds progress:0.4 waveform:waveform];
                [fresh settleMorphImmediately];
                XCTAssertTrue(VibeThreeBandPicture(reused).pixels == VibeThreeBandPicture(fresh).pixels,
                              @"%@ width %g", style, width);
            }
        }
    }
}

// One answer on every thread, kept while the summary stands.
- (void)testLoudestBandMeanSquaresAreTheSameOnEveryThread {
    auto waveform = VibeThreeBandTestWaveform({0.001f, 0.0001f, 0.00001f});
    AudioWaveform *shared = waveform.get();
    std::vector<std::array<float, 3>> answers(8);
    std::array<float, 3> *out = answers.data();
    dispatch_apply(answers.size(), DISPATCH_APPLY_AUTO, ^(size_t i) {
        shared->loudestMeanSquares(1024, 1, nullptr, out[i].data());
    });
    for (const auto &answer : answers) {
        XCTAssertTrue(answer == answers[0]);
    }
    XCTAssertEqualWithAccuracy(answers[0][0], 0.001f, 1e-7);
    XCTAssertEqualWithAccuracy(answers[0][1], 0.0001f, 1e-8);
    XCTAssertEqualWithAccuracy(answers[0][2], 0.00001f, 1e-9);
}

// The tallest band's height in pixels down each pixel column of 3-Band's
// picture at this width.
- (std::vector<CGFloat>)threeBandHeightsForWaveform:(AudioWaveform *)waveform width:(CGFloat)width {
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    CGRect bounds = CGRectMake(0, 0, width, 80);
    renderer.parentLayer.bounds = bounds;
    [renderer updateWaveform:bounds progress:0.5 waveform:waveform];
    [renderer settleMorphImmediately];
    VibeTestPicture picture = VibeThreeBandPicture(renderer);
    std::vector<CGFloat> heights;
    for (size_t x = 0; x < picture.width; x++) {
        CGFloat height = 0;
        for (size_t row = 0; row < picture.height; row++) height += picture.alpha(x, row) / 255.0;
        heights.push_back(height);
    }
    return heights;
}

// Zoomed in, the columns resolve a kick every eight bins, which the overview
// averages into one steady level.
- (void)testThreeBandZoomResolvesKicksTheOverviewAverages {
    std::vector<std::array<float, 3>> bands;
    for (NSUInteger i = 0; i < 8192; i++) {
        bands.push_back({i % 8 < 2 ? 0.04f : 0.0001f, 0.0001f, 0.00001f});
    }
    auto waveform = VibeTestWaveform(std::vector<VibeTestBin>(8192, {-0.1f, 0.1f, 0.01f}), bands);
    // Past the first and last points, whose windows may slide off the track.
    std::vector<CGFloat> overview = [self threeBandHeightsForWaveform:waveform.get() width:1024];
    XCTAssertEqualWithAccuracy(*std::max_element(overview.begin() + 2, overview.end() - 2),
                               *std::min_element(overview.begin() + 2, overview.end() - 2), 0.5);
    std::vector<CGFloat> zoomed = [self threeBandHeightsForWaveform:waveform.get() width:8192];
    XCTAssertGreaterThan(zoomed[8], 2 * zoomed[12], @"a kick against the gap after it");
    XCTAssertEqualWithAccuracy(zoomed[8], zoomed[16], 0.5);
}

// The fills are the theme's, by the set of bands each ring holds: the core,
// the low and mid ring and the low band's own, down the center column.
- (void)testThreeBandPaintsEachRingInTheThemesBandColor {
    std::array<float, 3> levels = {1, 0.01f, 0.0001f};
    VibeTestPicture picture = [self threeBandPictureForBands:levels normalize:NO centered:YES waveform:YES];
    std::vector<CGFloat> heights = VibeVisibleLayerHeights(picture);
    size_t center = picture.height / 2, x = picture.width / 2;
    size_t lowMidRow = center - (size_t)((heights[3] / 2 + heights[6] / 2) / 2);
    size_t lowRow = center - (size_t)((heights[0] / 2 + heights[3] / 2) / 2);
    XCTAssertEqual(picture.rgb(x, center), (uint32_t)(7 * 30) << 8, @"the core: all three bands");
    XCTAssertEqual(picture.rgb(x, lowMidRow), (uint32_t)(4 * 30) << 8, @"low and mid");
    XCTAssertEqual(picture.rgb(x, lowRow), (uint32_t)(1 * 30) << 8, @"low alone");
}

// The theme's gradient is Detailed's ramp over the sides: full at the top,
// dimmer toward the bottom. A flat theme drops it. The unplayed side is half
// the played one.
- (void)testThreeBandRampsLikeDetailedUnlessTheThemeIsFlat {
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    for (BOOL flatFill : {NO, YES}) {
        WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
        theme.flatFill = flatFill;
        renderer.theme = theme;
        [renderer updateColors:YES];
        NSArray<CAGradientLayer *> *sides = (NSArray<CAGradientLayer *> *)VibeThreeBandHost(renderer).mask.sublayers;
        XCTAssertEqual(sides.count, 2u);
        for (CAGradientLayer *side in sides) {
            CGFloat top = VibeAlphaOf(side.colors.firstObject), bottom = VibeAlphaOf(side.colors.lastObject);
            XCTAssertEqualWithAccuracy(bottom / top, flatFill ? 1 : kVibeBarGradientBottomAlpha, 1e-6);
        }
        XCTAssertEqualWithAccuracy(VibeAlphaOf(sides[1].colors.firstObject) / VibeAlphaOf(sides[0].colors.firstObject),
                                   0.5, 1e-6, @"the unplayed side's level");
    }
}

- (void)testThreeBandProgressSplitsTheSides {
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    CGFloat width = renderer.parentLayer.bounds.size.width;
    [renderer updateProgress:0.25 waveform:nullptr];
    NSArray<CALayer *> *sides = VibeThreeBandHost(renderer).mask.sublayers;
    XCTAssertEqual(CGRectGetMaxX(sides[0].frame), width * 0.25);
    XCTAssertEqual(CGRectGetMinX(sides[1].frame), width * 0.25);
    XCTAssertEqual(CGRectGetMaxX(sides[1].frame), width);
    XCTAssertEqual(VibeThreeBandHost(renderer).sublayers.count, 1u, @"one picture under the sides");
}

// The lit slice is masked by the picture itself, so it is the waveform's own
// column, and it shows only while hovered.
- (void)testThreeBandHoverIsMaskedByThePicture {
    auto waveform = VibeThreeBandTestWaveform({1, 0.01f, 0.0001f});
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    CALayer *host = renderer.parentLayer;
    [renderer updateWaveform:host.bounds progress:0.5 waveform:waveform.get()];
    [renderer settleMorphImmediately];
    CALayer *hoverHost = host.sublayers.firstObject.sublayers.lastObject;
    XCTAssertTrue(hoverHost.hidden);
    XCTAssertEqual(hoverHost.mask.contents, VibeThreeBandHost(renderer).sublayers.firstObject.contents);
    XCTAssertTrue(hoverHost.mask.contents != nil);
    [renderer setHoverHighlightX:100];
    XCTAssertFalse(hoverHost.hidden);
    [renderer setHoverHighlightX:-1];
    XCTAssertTrue(hoverHost.hidden);
}

- (void)testOnlyTheBandStylesReadTheBands {
    for (NSString *identifier in WaveformRendererRegistry.availableIdentifiers) {
        BOOL spectrum = [identifier isEqualToString:@"spectrum"];
        BOOL threeBand = [identifier isEqualToString:@"three_band"];
        XCTAssertEqual([WaveformRendererRegistry readsBandsForIdentifier:identifier], spectrum || threeBand,
                       @"%@", identifier);
        VibeWaveformPaletteKind expected = spectrum ? VibeWaveformPaletteKindSpectrum
                : threeBand ? VibeWaveformPaletteKindBands : VibeWaveformPaletteKindTheme;
        XCTAssertEqual([WaveformRendererRegistry paletteKindForIdentifier:identifier], expected, @"%@", identifier);
    }
    XCTAssertFalse([WaveformRendererRegistry readsBandsForIdentifier:nil]);
    XCTAssertFalse([WaveformRendererRegistry readsBandsForIdentifier:@"missing-style"]);
    XCTAssertEqual([WaveformRendererRegistry paletteKindForIdentifier:nil], VibeWaveformPaletteKindTheme);
    XCTAssertEqual([WaveformRendererRegistry paletteKindForIdentifier:@"missing-style"],
                   VibeWaveformPaletteKindTheme);
}

- (void)testSwatchColorsFollowTheStyle {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    NSArray<VibeColor *> *played = @[theme.playedColor, theme.playedColor, theme.playedColor];
    XCTAssertEqualObjects([WaveformRendererRegistry swatchColorsForIdentifier:@"three_band" theme:theme],
                          [theme.bandColors subarrayWithRange:NSMakeRange(0, 3)]);
    XCTAssertEqualObjects([WaveformRendererRegistry swatchColorsForIdentifier:@"spectrum" theme:theme],
                          theme.spectrumColors);
    for (NSString *identifier in @[@"detailed", @"wiggle_centered", @"missing-style"]) {
        XCTAssertEqualObjects([WaveformRendererRegistry swatchColorsForIdentifier:identifier theme:theme], played,
                              @"%@", identifier);
    }
    XCTAssertEqualObjects([WaveformRendererRegistry swatchColorsForIdentifier:nil theme:theme], played);
}

#pragma mark - Spectrum

static uint32_t VibeSRGBOf(VibeColor *color) {
    CGFloat r = 0, g = 0, b = 0;
    VibeColorGetSRGB(color, &r, &g, &b);
    return (uint32_t)lround(r * 255) << 16 | (uint32_t)lround(g * 255) << 8 | (uint32_t)lround(b * 255);
}

- (VibeTestPicture)spectrumPictureForWaveform:(AudioWaveform *)waveform scale:(CGFloat)scale
                                        theme:(WaveformTheme *)theme {
    WaveformRenderer *renderer = [self rendererForStyle:@"spectrum"];
    renderer.parentLayer.contentsScale = scale;
    renderer.theme = theme;
    [renderer updateColors:YES];
    [renderer updateWaveform:renderer.parentLayer.bounds progress:0.5 waveform:waveform];
    [renderer settleMorphImmediately];
    XCTAssertEqual(VibeThreeBandHost(renderer).sublayers.count, 1u, @"one picture in place of the band layers");
    return VibeThreeBandPicture(renderer);
}

- (uint32_t)spectrumCenterRGBForBands:(std::array<float, 3>)bands theme:(WaveformTheme *)theme {
    auto waveform = VibeThreeBandTestWaveform(bands);
    VibeTestPicture picture = [self spectrumPictureForWaveform:waveform.get() scale:1 theme:theme];
    XCTAssertEqual(picture.width, 512u, @"a pixel per backing pixel");
    return picture.width ? picture.rgb(picture.width / 2, picture.height / 2) : 0;
}

- (void)testSpectrumFillsTheOutlineWithEachBarsMix {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    theme.flatFill = YES;
    uint32_t low = VibeSRGBOf(theme.spectrumColors[0]);
    uint32_t high = VibeSRGBOf(theme.spectrumColors[2]);
    // Outside the asserts: a braced list's commas split a macro's arguments.
    uint32_t lowAlone = [self spectrumCenterRGBForBands:{1, 0, 0} theme:theme];
    uint32_t highAlone = [self spectrumCenterRGBForBands:{0, 0, 1} theme:theme];
    XCTAssertEqual(lowAlone, low);
    XCTAssertEqual(highAlone, high);
    uint32_t purple = [self spectrumCenterRGBForBands:{1, 0, 0.48f * 0.48f} theme:theme];
    uint32_t red = purple >> 16 & 0xff, green = purple >> 8 & 0xff, blue = purple & 0xff;
    XCTAssertGreaterThan(red, green);
    XCTAssertGreaterThan(blue, green);
    XCTAssertNotEqual(purple, low);
    XCTAssertNotEqual(purple, high);
}

// The picture's colors along its middle row for a waveform whose bins
// alternate between a low band and a high band every period bins.
- (std::vector<uint32_t>)spectrumRGBForAlternationPeriod:(NSUInteger)period scale:(CGFloat)scale
                                                  theme:(WaveformTheme *)theme {
    std::vector<std::array<float, 3>> bands;
    for (NSUInteger i = 0; i < 1024; i++) {
        bool low = (i / period) % 2 == 0;
        bands.push_back({low ? 1.0f : 0.0f, 0.0f, low ? 0.0f : 0.2f});
    }
    auto waveform = VibeTestWaveform(std::vector<VibeTestBin>(1024, {-0.1f, 0.1f, 0.01f}), bands);
    VibeTestPicture picture = [self spectrumPictureForWaveform:waveform.get() scale:scale theme:theme];
    std::vector<uint32_t> rgb;
    for (size_t x = 0; x < picture.width; x++) {
        rgb.push_back(picture.rgb(x, picture.height / 2));
    }
    return rgb;
}

// The height reach would mix neighboring bands into identical colors. The
// tent is 1/256 of the track foot to foot: four bins here, two columns at a
// column a pixel, so a column's own band leads with a quarter of each
// neighbor's.
- (void)testSpectrumColorsEachBarByItsOwnBandDownToTheTent {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    theme.flatFill = YES;
    std::vector<uint32_t> rgb = [self spectrumRGBForAlternationPeriod:2 scale:1 theme:theme];
    XCTAssertEqual(rgb.size(), 1024u / 2);
    if (rgb.size() == 512) {
        XCTAssertGreaterThan(rgb[256] >> 16 & 0xff, rgb[256] & 0xff, @"red leads a low column");
        XCTAssertGreaterThan(rgb[257] & 0xff, rgb[257] >> 16 & 0xff, @"blue leads a high column");
        XCTAssertNotEqual(rgb[256], VibeSRGBOf(theme.spectrumColors[0]), @"a quarter of each neighbor");
        XCTAssertNotEqual(rgb[257], VibeSRGBOf(theme.spectrumColors[2]));
    }
}

// Columns finer than the tent read the tent about their centers, so bins
// alternating every bin color every one-bin column the same.
- (void)testSpectrumColorsBarsFinerThanTheTentByTheTent {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    theme.flatFill = YES;
    std::vector<uint32_t> rgb = [self spectrumRGBForAlternationPeriod:1 scale:2 theme:theme];
    XCTAssertEqual(rgb.size(), 1024u);
    if (rgb.size() == 1024) {
        XCTAssertEqual(rgb[512], rgb[513]);
        XCTAssertNotEqual(rgb[512], VibeSRGBOf(theme.spectrumColors[0]));
        XCTAssertNotEqual(rgb[512], VibeSRGBOf(theme.spectrumColors[2]));
    }
}

// Spectrum's outline is the tallest band: 3-Band's outer ring.
- (void)testSpectrumOutlineIsTheTallestBand {
    std::array<float, 3> bands = {1, 0.01f, 0.0001f};
    auto waveform = VibeThreeBandTestWaveform(bands);
    VibeTestPicture spectrum = [self spectrumPictureForWaveform:waveform.get() scale:1
                                                          theme:[WaveformTheme monochromeThemeIsDark:YES]];
    VibeTestPicture threeBand = [self threeBandPictureForBands:bands normalize:NO centered:YES waveform:YES];
    XCTAssertEqualWithAccuracy(VibeLitBounds(spectrum, 128).size.height, VibeLitBounds(threeBand, 128).size.height, 0.5);
}

#pragma mark - The convert sweep

// The ink down one pixel column of a picture.
static CGFloat VibeInkAt(const VibeTestPicture &picture, size_t x) {
    CGFloat ink = 0;
    for (size_t row = 0; row < picture.height; row++) ink += picture.alpha(x, row) / 255.0;
    return ink;
}

// The convert sweep zeroes a step style's columns over the span in every
// step, so the notch is a hairline, and the ease brings them back.
- (void)testTheConvertSweepDipsAStepStylesColumns {
    auto steady = VibeTestSteadyWaveform(8192, {-0.5f, 0.5f, 0.25f});
    auto banded = VibeThreeBandTestWaveform({1, 0.01f, 0.0001f});
    for (NSString *style in @[@"detailed", @"oversampling_detailed_x4", @"three_band"]) {
        BOOL bands = [style isEqualToString:@"three_band"];
        WaveformRenderer *renderer = [self rendererForStyle:style];
        CALayer *host = renderer.parentLayer;
        [renderer updateWaveform:host.bounds progress:0 waveform:bands ? banded.get() : steady.get()];
        [renderer settleMorphImmediately];
        VibeTestPicture (^picture)(void) = ^VibeTestPicture {
            return bands ? VibeThreeBandPicture(renderer) : VibePictureOf(VibeMaskLayer(renderer));
        };
        // Pixel 256 is inside the span, at half the track; pixel 64 is not.
        CGFloat inside = VibeInkAt(picture(), 256), outside = VibeInkAt(picture(), 64);
        XCTAssertGreaterThan(inside, 20, @"%@", style);
        [renderer dipBarsFromFraction:0.4 toFraction:0.6];
        XCTAssertLessThan(VibeInkAt(picture(), 256), 2.5, @"%@: a hairline in the span", style);
        XCTAssertEqualWithAccuracy(VibeInkAt(picture(), 64), outside, 0.5, @"%@: untouched outside it", style);
        [renderer settleMorphImmediately];
        XCTAssertEqualWithAccuracy(VibeInkAt(picture(), 256), inside, 0.5, @"%@: eased back", style);
    }
}

@end
