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
#include <vector>

@interface AudioWaveformTests : XCTestCase
@end

@implementation AudioWaveformTests

// Normalize's reference: the track's own, whatever the view draws.
static float VibeTestFullScaleRMS(AudioWaveform *waveform, BOOL normalize) {
    return VibeWaveformFullScaleRMSForWaveform(waveform, normalize);
}

- (WaveformRenderer *)rendererForStyle:(NSString *)identifier {
    CALayer *host = [CALayer layer];
    host.bounds = CGRectMake(0, 0, 512, 80);
    return [WaveformRendererRegistry rendererForResolvedIdentifier:identifier
            layer:host bounds:host.bounds isDark:YES];
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
            boxes[centered] = CGPathGetPathBoundingBox(((CAShapeLayer *)host.sublayers.firstObject.mask).path);
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
            CAShapeLayer *mask = (CAShapeLayer *)host.sublayers.firstObject.mask;
            CGFloat pitch = 512.0 / count;
            CGFloat original = sonic ? host.sublayers.firstObject.bounds.size.width
                    : wiggle ? mask.lineWidth : CGPathGetPathBoundingBox(mask.path).size.width - pitch * (count - 1);
            for (CGFloat width : {0.5, 2.0}) {
                renderer.barWidthScale = width;
                XCTAssertEqual(sonic ? host.sublayers.count / 2 : [detailed numBarsForWidth:512], count);
                CGFloat actual = sonic ? host.sublayers.firstObject.bounds.size.width
                        : wiggle ? mask.lineWidth : CGPathGetPathBoundingBox(mask.path).size.width - pitch * (count - 1);
                XCTAssertEqualWithAccuracy(actual, MIN(original * width, pitch), 1e-6, @"%@ density %g", style, density);
                if (!sonic) {
                    CGRect bounds = CGPathGetPathBoundingBox(mask.path);
                    CGFloat inset = wiggle ? mask.lineWidth / 2 : 0;
                    XCTAssertGreaterThanOrEqual(CGRectGetMinX(bounds) - inset, -1e-6);
                    XCTAssertLessThanOrEqual(CGRectGetMaxX(bounds) + inset, 512 + 1e-6);
                }
            }
        }
    }
}

- (void)testNormalizationOnlyRaisesLevelsAndKeepsSilenceFinite {
    for (float rms : {0.0f, 0.000001f, 0.035f, 0.35f, 0.7f, 1.0f}) {
        auto waveform = VibeTestSteadyWaveform(1, {-rms, rms, rms * rms});
        float plain = VibeTestFullScaleRMS(waveform.get(), NO);
        float normalized = VibeTestFullScaleRMS(waveform.get(), YES);
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

// Normalize's reference is the track's loudest 1/1024 column, so the bars
// fine enough to draw it reach full height and coarser ones never pass it.
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
        for (CGFloat width : {257.0, 512.0, 773.0}) {
            NSUInteger count = [renderer numBarsForWidth:width];
            std::vector<float> plain(count * 2), normalized(count * 2);
            for (float gain : {-12.0f, 0.0f, 12.0f}) {
                renderer.gainDB = gain;
                renderer.normalizesLevels = NO;
                [renderer fillEnvelope:plain.data() barCount:count waveform:waveform.get()];
                renderer.normalizesLevels = YES;
                [renderer fillEnvelope:normalized.data() barCount:count waveform:waveform.get()];
                for (NSUInteger i = 0; i < count; i++) {
                    XCTAssertLessThanOrEqual(normalized[i * 2], plain[i * 2], @"%@", identifier);
                    XCTAssertGreaterThanOrEqual(normalized[i * 2 + 1], plain[i * 2 + 1], @"%@", identifier);
                }
                if (gain == 0) {
                    float tallest = *std::max_element(normalized.begin(), normalized.end());
                    if (count >= kVibeWaveformEnergyColumns) {
                        XCTAssertEqualWithAccuracy(tallest, 1, 1e-6, @"%@", identifier);
                    } else {
                        XCTAssertLessThanOrEqual(tallest, 1 + 1e-6, @"%@", identifier);
                    }
                }
            }
        }
    }
}

// Past 1,024 bars a column's bars need not cover its chunks. A transient one
// of them misses must still set the column's peak, or the quiet bars beside it
// are scaled up to its level.
- (void)testDetailedQuietBarsBesideATransientStayQuiet {
    std::vector<VibeTestBin> bins(8192, {-0.01f, 0.01f, 0.0001f});
    bins[816] = {-0.5f, 0.5f, 0.25f};
    auto waveform = VibeTestWaveform(bins);
    DetailedWaveformRenderer *renderer = (DetailedWaveformRenderer *)[self rendererForStyle:@"detailed"];
    for (CGFloat width : {930.0, 931.0, 1200.0}) {
        NSUInteger count = [renderer numBarsForWidth:width];
        XCTAssertGreaterThan(count, kVibeWaveformEnergyColumns);
        std::vector<float> envelope(count * 2);
        [renderer fillEnvelope:envelope.data() barCount:count waveform:waveform.get()];
        for (NSUInteger i = 0; i < count; i++) {
            if (VibeTestColumn(waveform.get(), i, count).hi < 0.1f) {
                XCTAssertLessThan(envelope[i * 2 + 1], 0.05f, @"width %g bar %lu", width, i);
            }
        }
    }
}

// A bar straddling into the next column's transient widens only its own
// reference: the bars beside it, which hold none of it, keep their height.
- (void)testDetailedBarsBesideAStraddlingTransientKeepTheirHeight {
    std::vector<VibeTestBin> steady(8192, {-0.1f, 0.1f, 0.01f}), bins = steady;
    bins[816] = {-0.9f, 0.9f, 0.81f};
    auto waveform = VibeTestWaveform(bins), background = VibeTestWaveform(steady);
    DetailedWaveformRenderer *renderer = (DetailedWaveformRenderer *)[self rendererForStyle:@"detailed"];
    for (CGFloat width : {930.0, 931.0, 1200.0}) {
        NSUInteger count = [renderer numBarsForWidth:width];
        std::vector<float> envelope(count * 2), plain(count * 2);
        [renderer fillEnvelope:envelope.data() barCount:count waveform:waveform.get()];
        [renderer fillEnvelope:plain.data() barCount:count waveform:background.get()];
        for (NSUInteger i = 0; i < count; i++) {
            NSUInteger column = VibeWaveformEnergyColumnIndexForBar(i, count);
            BOOL touched = VibeTestColumn(waveform.get(), i, count).hi > 0.5f ||
                    VibeTestColumn(waveform.get(), column, kVibeWaveformEnergyColumns).hi > 0.5f;
            if (!touched) {
                XCTAssertEqualWithAccuracy(envelope[i * 2 + 1], plain[i * 2 + 1], 1e-3, @"width %g bar %lu", width, i);
            }
        }
    }
}

// Normalize only raises, and its reference is the track's, so the gain it
// applies is the same at every width.
- (void)testLayerStylesOnlyGrowUnderNormalization {
    std::vector<VibeTestBin> bins(1024, {-0.1f, 0.1f, 0.01f});
    bins[511] = {-0.5f, 0.5f, 0.1f};
    auto waveform = VibeTestWaveform(bins);
    for (NSString *identifier in @[@"sonic_cirrus", @"cupertino_basic"]) {
        WaveformRenderer *renderer = [self rendererForStyle:identifier];
        CALayer *host = renderer.parentLayer;
        CGFloat gainAtFirstWidth = 0;
        for (CGFloat width : {257.0, 512.0, 773.0}) {
            host.bounds = CGRectMake(0, 0, width, 80);
            renderer.normalizesLevels = YES;
            CGFloat gainHere = [renderer normalizationGainForWaveform:waveform.get()];
            if (gainAtFirstWidth == 0) gainAtFirstWidth = gainHere;
            XCTAssertEqual(gainHere, gainAtFirstWidth, @"%@ width %g", identifier, width);
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
    for (NSString *identifier in @[@"detailed", @"wiggle_centered"]) {
        DetailedWaveformRenderer *renderer = (DetailedWaveformRenderer *)[self rendererForStyle:identifier];
        BOOL wiggle = ![identifier isEqualToString:@"detailed"];
        XCTAssertEqual(renderer.class, DetailedWaveformRenderer.class);
        XCTAssertEqual([renderer numBarsForWidth:512], wiggle ? 64u : 1024u);
        renderer.samplingWidth = 512;
        XCTAssertEqual([renderer numBarsForWidth:2048], wiggle ? 64u : 4096u,
                       @"Zoom must preserve Wiggle's loops without reducing Detailed's resolution");
        renderer.samplingWidth = 768;
        XCTAssertEqual([renderer numBarsForWidth:2048], wiggle ? 96u : 4096u);
    }
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
        CAShapeLayer *mask = (CAShapeLayer *)host.sublayers.firstObject.mask;
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
    XCTAssertEqual(VibeTestFullScaleRMS(snapshot.get(), YES), kVibeWaveformFullScaleRMS);

    auto whole = VibeTestSteadyWaveform(8192, {-0.1f, 0.1f, 0.01f});
    XCTAssertTrue(whole->isComplete());
    XCTAssertEqualWithAccuracy(VibeTestFullScaleRMS(whole.get(), YES), 0.1f, 1e-6);
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

// 32-bit host order, alpha first: B, G, R, A in memory.
static uint32_t VibeARGBAt(CGImageRef image, size_t row, size_t column) {
    NSData *pixels = CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
    const uint8_t *p = (const uint8_t *)pixels.bytes + row * CGImageGetBytesPerRow(image) + column * 4;
    return (uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0];
}
static uint32_t VibeRGBAt(CGImageRef image, size_t row, size_t column) {
    return VibeARGBAt(image, row, column) & 0xffffff;
}

// The band layers' host, which the sides' mask covers.
static CALayer *VibeThreeBandHost(WaveformRenderer *renderer) {
    return renderer.parentLayer.sublayers.firstObject.sublayers.firstObject;
}

static NSArray<CAShapeLayer *> *VibeThreeBandLayers(WaveformRenderer *renderer) {
    return (NSArray<CAShapeLayer *> *)VibeThreeBandHost(renderer).sublayers;
}

static CGFloat VibeAlphaOf(id color) {
    return CGColorGetAlpha((__bridge CGColorRef)color);
}

static NSUInteger VibeSubpathCount(CGPathRef path) {
    __block NSUInteger count = 0;
    CGPathApplyWithBlock(path, ^(const CGPathElement *element) {
        if (element->type == kCGPathElementMoveToPoint) count++;
    });
    return count;
}

// Each layer's drawn height for VibeThreeBandTestWaveform (0 where it draws
// nothing).
- (std::vector<CGFloat>)threeBandLayerHeightsForBands:(std::array<float, 3>)bands
                                            normalize:(BOOL)normalize
                                             waveform:(BOOL)hasWaveform {
    auto waveform = VibeThreeBandTestWaveform(bands);
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    renderer.normalizesLevels = normalize;
    CALayer *host = renderer.parentLayer;
    [renderer updateWaveform:host.bounds progress:0.5 waveform:hasWaveform ? waveform.get() : nullptr];
    [renderer settleMorphImmediately];
    NSArray<CAShapeLayer *> *stack = VibeThreeBandLayers(renderer);
    XCTAssertEqual(stack.count, kThreeBandLayers);
    std::vector<CGFloat> heights;
    for (CAShapeLayer *layer in stack) {
        CGPathRef path = layer.path;
        heights.push_back(path && !CGPathIsEmpty(path) ? CGPathGetPathBoundingBox(path).size.height : 0);
    }
    return heights;
}

- (std::vector<CGFloat>)threeBandLayerHeightsForBands:(std::array<float, 3>)bands {
    return [self threeBandLayerHeightsForBands:bands normalize:NO waveform:YES];
}

// What shows of each layer when every bar is alike: every set's envelope is
// built, and a layer no taller than one painted after it is covered.
- (std::vector<CGFloat>)visibleThreeBandLayerHeightsForBands:(std::array<float, 3>)bands {
    std::vector<CGFloat> visible = [self threeBandLayerHeightsForBands:bands];
    CGFloat above = 0;
    for (NSUInteger layer = visible.size(); layer-- > 0;) {
        CGFloat drawn = visible[layer];
        if (drawn <= above) visible[layer] = 0;
        above = MAX(above, drawn);
    }
    return visible;
}

// Grounded, every band set stands on the baseline at its centered height, so
// the rings still nest.
- (void)testGroundedThreeBandStandsOnTheBaseline {
    auto waveform = VibeThreeBandTestWaveform({1, 0.01f, 0.0001f});
    std::vector<CGRect> boxes[2];
    for (BOOL centered : {YES, NO}) {
        WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
        renderer.centered = centered;
        [renderer updateWaveform:renderer.parentLayer.bounds progress:0.5 waveform:waveform.get()];
        [renderer settleMorphImmediately];
        for (CAShapeLayer *layer in VibeThreeBandLayers(renderer)) {
            boxes[centered].push_back(CGPathGetPathBoundingBox(layer.path));
        }
    }
    for (NSUInteger layer = 0; layer < kThreeBandLayers; layer++) {
        XCTAssertEqualWithAccuracy(boxes[NO][layer].size.height, boxes[YES][layer].size.height, 1e-3, @"layer %lu", layer);
        XCTAssertEqualWithAccuracy(CGRectGetMinY(boxes[NO][layer]), VibeBarBaseline(80), 1e-3, @"layer %lu", layer);
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

    // A loud low, a mid and a faint high: blue out to the low, brown out to
    // the mid, the all-bands core out to the high.
    std::vector<CGFloat> nested = [self visibleThreeBandLayerHeightsForBands:{1, 0.01f, 0.0001f}];
    XCTAssertGreaterThan(nested[0], nested[3]);
    XCTAssertGreaterThan(nested[3], nested[6]);
    XCTAssertGreaterThan(nested[6], 0);
    XCTAssertEqual(nested[1] + nested[2] + nested[4] + nested[5], 0);

    // The same, led by the high band: white, then mid+high, then the core.
    std::vector<CGFloat> bright = [self visibleThreeBandLayerHeightsForBands:{0.0001f, 0.01f, 1}];
    XCTAssertGreaterThan(bright[2], bright[5]);
    XCTAssertGreaterThan(bright[5], bright[6]);
    XCTAssertEqual(bright[0] + bright[1] + bright[3] + bright[4], 0);
}

- (void)testThreeBandSilenceIsAHairlineAndNoWaveformIsNothing {
    std::vector<CGFloat> silence = [self visibleThreeBandLayerHeightsForBands:{0, 0, 0}];
    std::vector<CGFloat> empty = [self threeBandLayerHeightsForBands:{0, 0, 0} normalize:NO waveform:NO];
    for (NSUInteger layer = 0; layer < kThreeBandLayers; layer++) {
        XCTAssertEqual(silence[layer], layer == kThreeBandLayers - 1 ? 1 : 0, @"layer %lu", layer);
        XCTAssertEqual(empty[layer], 0, @"layer %lu", layer);
    }
}

// Under Normalize, the tallest band against its share reaches full height,
// whichever band it is; a band already past full stays where it was.
- (void)testThreeBandNormalizeFillsTheTallestBand {
    CGFloat full = 2 * VibeBarVScale([self rendererForStyle:@"three_band"].parentLayer.bounds.size.height);
    std::vector<CGFloat> lowLed = [self threeBandLayerHeightsForBands:{0.001f, 0.0001f, 0.00001f}
                                                            normalize:YES waveform:YES];
    XCTAssertEqualWithAccuracy(lowLed[0], full, 0.01);
    std::vector<CGFloat> highLed = [self threeBandLayerHeightsForBands:{0.00001f, 0.00001f, 0.001f}
                                                             normalize:YES waveform:YES];
    XCTAssertEqualWithAccuracy(highLed[2], full, 0.01);
    std::array<float, 3> loud = {1, 0.01f, 0.0001f};
    XCTAssertTrue([self threeBandLayerHeightsForBands:loud normalize:YES waveform:YES] ==
                  [self threeBandLayerHeightsForBands:loud]);
}

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
                WaveformRenderer *fresh = [self rendererForStyle:style];
                fresh.normalizesLevels = YES;
                fresh.parentLayer.bounds = bounds;
                XCTAssertEqualObjects([reused envelopeSamplesForWaveform:waveform],
                                      [fresh envelopeSamplesForWaveform:waveform], @"%@ width %g", style, width);
                XCTAssertEqual([reused normalizationGainForWaveform:waveform],
                               [fresh normalizationGainForWaveform:waveform]);
            }
            reused.normalizesLevels = NO;
            XCTAssertEqual([reused normalizationGainForWaveform:waveform], 1);
            reused.normalizesLevels = YES;
        }
        XCTAssertEqualWithAccuracy([reused normalizationGainForWaveform:quiet.get()],
                                  kVibeWaveformFullScaleRMS / sqrtf(0.001f), 1e-4, @"%@", style);
        XCTAssertEqualWithAccuracy([reused normalizationGainForWaveform:loud.get()],
                                  kVibeWaveformFullScaleRMS / fminf(sqrtf(0.1f), kVibeWaveformFullScaleRMS), 1e-6, @"%@", style);
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

// The bars' levels, low to high, as 3-Band draws them across this width.
- (std::vector<float>)threeBandLevelsForWaveform:(AudioWaveform *)waveform width:(CGFloat)width {
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    CGRect bounds = renderer.parentLayer.bounds;
    renderer.parentLayer.bounds = CGRectMake(0, 0, width, bounds.size.height);
    NSData *samples = [renderer envelopeSamplesForWaveform:waveform];
    const float *levels = (const float *)samples.bytes;
    return std::vector<float>(levels, levels + samples.length / sizeof(float));
}

- (void)testThreeBandBarsFollowTheDrawnWidth {
    auto waveform = VibeThreeBandTestWaveform({1, 0.01f, 0.0001f});
    for (std::array<CGFloat, 2> widthAndBars : {std::array<CGFloat, 2>{512, 512}, {3000, 3000}, {20000, 8192}}) {
        XCTAssertEqual([self threeBandLevelsForWaveform:waveform.get() width:widthAndBars[0]].size(),
                       (NSUInteger)widthAndBars[1] * wavecore::kBandCount);
    }
}

// Zoomed in, the bars resolve a kick every eight bins, which the 1/1024
// floor would average into one steady column.
- (void)testThreeBandZoomResolvesKicksTheFloorAverages {
    std::vector<std::array<float, 3>> bands;
    for (NSUInteger i = 0; i < 8192; i++) {
        bands.push_back({i % 8 < 2 ? 0.04f : 0.0001f, 0.0001f, 0.00001f});
    }
    auto waveform = VibeTestWaveform(std::vector<VibeTestBin>(8192, {-0.1f, 0.1f, 0.01f}), bands);
    auto lowLevels = [&](CGFloat width) {
        std::vector<float> levels = [self threeBandLevelsForWaveform:waveform.get() width:width];
        std::vector<float> low;
        for (NSUInteger i = 0; i < levels.size(); i += wavecore::kBandCount) low.push_back(levels[i]);
        return low;
    };
    // Past the first and last bars, whose windows may slide off the track.
    std::vector<float> overview = lowLevels(1024);
    XCTAssertEqualWithAccuracy(*std::max_element(overview.begin() + 1, overview.end() - 1),
                               *std::min_element(overview.begin() + 1, overview.end() - 1), 1e-5);
    std::vector<float> zoomed = lowLevels(8192);
    XCTAssertGreaterThan(zoomed[0], 3 * zoomed[4]);
    XCTAssertEqualWithAccuracy(zoomed[0], zoomed[8], 1e-6);
}

- (void)testThreeBandDrawsOneOutlinePerLayer {
    auto waveform = VibeThreeBandTestWaveform({1, 0.01f, 0.0001f});
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    [renderer updateWaveform:renderer.parentLayer.bounds progress:0.5 waveform:waveform.get()];
    [renderer settleMorphImmediately];
    for (CAShapeLayer *layer in VibeThreeBandLayers(renderer)) {
        XCTAssertEqual(VibeSubpathCount(layer.path), 1u);
    }
}

// The band fills are the theme's, live and baked alike: the bake's core,
// low+mid ring and low band's own, read at the bitmap's center column.
- (void)testThreeBandPaintsEachRingInTheThemesBandColor {
    std::array<float, 3> levels = {1, 0.01f, 0.0001f};
    auto waveform = VibeThreeBandTestWaveform(levels);
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    theme.flatFill = YES;
    NSMutableArray<VibeColor *> *bands = [NSMutableArray array];
    for (NSUInteger layer = 0; layer < kThreeBandLayers; layer++) {
        [bands addObject:[NSColor colorWithSRGBRed:0 green:(layer + 1) * 30 / 255.0 blue:0 alpha:1]];
    }
    theme.bandColors = bands;
    renderer.theme = theme;
    [renderer updateColors:YES];
    NSArray<CAShapeLayer *> *stack = VibeThreeBandLayers(renderer);
    for (NSUInteger layer = 0; layer < kThreeBandLayers; layer++) {
        XCTAssertTrue(CGColorEqualToColor(stack[layer].fillColor, bands[layer].CGColor), @"layer %lu",
                      (unsigned long)layer);
    }
    XCTAssertTrue(renderer.supportsEnvelopeBake);
    CGSize size = renderer.parentLayer.bounds.size;
    CGImageRef image = [renderer newEnvelopeImageForSize:size scale:1
                                                 samples:[renderer envelopeSamplesForWaveform:waveform.get()]];
    XCTAssertTrue(image != NULL);
    XCTAssertTrue([renderer newUnplayedEnvelopeImageForSize:size scale:1 samples:NSData.data] == NULL,
                  @"the unplayed side is the one bitmap, dimmed");
    XCTAssertLessThan([renderer unplayedOverPlayedOpacity], 1);
    size_t center = CGImageGetHeight(image) / 2;
    std::vector<CGFloat> heights = [self threeBandLayerHeightsForBands:levels];
    size_t lowMidRow = center - (size_t)((heights[3] / 2 + heights[6] / 2) / 2);
    size_t lowRow = center - (size_t)((heights[0] / 2 + heights[3] / 2) / 2);
    XCTAssertEqual(VibeRGBAt(image, center, 256), (uint32_t)(7 * 30) << 8, @"the core: all three bands");
    XCTAssertEqual(VibeRGBAt(image, lowMidRow, 256), (uint32_t)(4 * 30) << 8, @"low and mid");
    XCTAssertEqual(VibeRGBAt(image, lowRow, 256), (uint32_t)(1 * 30) << 8, @"low alone");
    CGImageRelease(image);
}

// The theme's gradient is Detailed's ramp, live and baked alike: full at the
// top, dimmer toward the bottom. A flat theme drops it.
- (void)testThreeBandRampsLikeDetailedUnlessTheThemeIsFlat {
    auto waveform = VibeThreeBandTestWaveform({1, 0.01f, 0.0001f});
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    CGSize size = renderer.parentLayer.bounds.size;
    // Inside the bands, the same distance above and below the midline; row 0
    // is the image's top.
    size_t offset = (size_t)(VibeBarVScale(size.height) * 0.5);
    size_t upper = (size_t)size.height / 2 - offset, lower = (size_t)size.height / 2 + offset;
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
                                   renderer.unplayedOverPlayedOpacity, 1e-6, @"the unplayed side's level");
        CGImageRef image = [renderer newEnvelopeImageForSize:size scale:1
                                                     samples:[renderer envelopeSamplesForWaveform:waveform.get()]];
        uint32_t upperAlpha = VibeARGBAt(image, upper, 256) >> 24;
        uint32_t lowerAlpha = VibeARGBAt(image, lower, 256) >> 24;
        if (flatFill) {
            XCTAssertEqual(upperAlpha, 255u);
            XCTAssertEqual(lowerAlpha, 255u);
        } else {
            XCTAssertGreaterThan(upperAlpha, lowerAlpha + 40);
            XCTAssertGreaterThan(lowerAlpha, (uint32_t)(255 * kVibeBarGradientBottomAlpha));
        }
        CGImageRelease(image);
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
    XCTAssertEqual(VibeThreeBandLayers(renderer).count, kThreeBandLayers);
}

- (void)testThreeBandBuildsItsHoverOutlineOnlyWhileShown {
    std::array<float, 3> bands = {1, 0.01f, 0.0001f};
    auto waveform = VibeThreeBandTestWaveform(bands);
    WaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    CALayer *host = renderer.parentLayer;
    [renderer updateWaveform:host.bounds progress:0.5 waveform:waveform.get()];
    [renderer settleMorphImmediately];
    CALayer *hoverHost = host.sublayers.firstObject.sublayers.lastObject;
    CAShapeLayer *outline = (CAShapeLayer *)hoverHost.mask;
    XCTAssertTrue(hoverHost.hidden);
    XCTAssertTrue(!outline.path || CGPathIsEmpty(outline.path));
    [renderer setHoverHighlightX:100];
    XCTAssertFalse(hoverHost.hidden);
    CGFloat lowHeight = [self threeBandLayerHeightsForBands:bands][0];
    XCTAssertEqual(CGPathGetPathBoundingBox(outline.path).size.height, lowHeight);
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

// The live strip's pixel at column, as 0xRRGGBB: the strip is R, G, B, X in
// memory.
static uint32_t VibeStripRGBAt(CGImageRef strip, size_t column) {
    NSData *pixels = CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(strip)));
    const uint8_t *p = (const uint8_t *)pixels.bytes + column * 4;
    return (uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2];
}

- (uint32_t)spectrumCenterRGBForBands:(std::array<float, 3>)bands theme:(WaveformTheme *)theme {
    auto waveform = VibeThreeBandTestWaveform(bands);
    WaveformRenderer *renderer = [self rendererForStyle:@"spectrum"];
    renderer.theme = theme;
    [renderer updateColors:YES];
    [renderer updateWaveform:renderer.parentLayer.bounds progress:0.5 waveform:waveform.get()];
    [renderer settleMorphImmediately];
    NSArray<CALayer *> *fills = VibeThreeBandHost(renderer).sublayers;
    XCTAssertEqual(fills.count, 1u, @"one strip in place of the band layers");
    CGImageRef strip = (__bridge CGImageRef)fills.firstObject.contents;
    XCTAssertTrue(strip != NULL);
    XCTAssertEqual(CGImageGetWidth(strip), 512u, @"a pixel per backing pixel");
    XCTAssertEqual(VibeSubpathCount(((CAShapeLayer *)fills.firstObject.mask).path), 1u);
    CGSize size = renderer.parentLayer.bounds.size;
    CGImageRef image = [renderer newEnvelopeImageForSize:size scale:1
                                                 samples:[renderer envelopeSamplesForWaveform:waveform.get()]];
    XCTAssertTrue(image != NULL);
    uint32_t baked = image ? VibeRGBAt(image, CGImageGetHeight(image) / 2, 256) : 0;
    CGImageRelease(image);
    if (strip) {
        XCTAssertEqual(VibeStripRGBAt(strip, 256), baked, @"the live strip and the bake agree");
    }
    return baked;
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

// The strip's pixel colors for a waveform whose bins alternate between a low
// band and a high band every period bins, at scale bars per point.
- (std::vector<uint32_t>)spectrumStripRGBForAlternationPeriod:(NSUInteger)period scale:(CGFloat)scale
                                                        theme:(WaveformTheme *)theme {
    std::vector<std::array<float, 3>> bands;
    for (NSUInteger i = 0; i < 1024; i++) {
        bool low = (i / period) % 2 == 0;
        bands.push_back({low ? 1.0f : 0.0f, 0.0f, low ? 0.0f : 0.2f});
    }
    auto waveform = VibeTestWaveform(std::vector<VibeTestBin>(1024, {-0.1f, 0.1f, 0.01f}), bands);
    WaveformRenderer *renderer = [self rendererForStyle:@"spectrum"];
    renderer.parentLayer.contentsScale = scale;
    renderer.theme = theme;
    [renderer updateColors:YES];
    [renderer updateWaveform:renderer.parentLayer.bounds progress:0.5 waveform:waveform.get()];
    [renderer settleMorphImmediately];
    CGImageRef strip = (__bridge CGImageRef)VibeThreeBandHost(renderer).sublayers.firstObject.contents;
    XCTAssertTrue(strip != NULL);
    std::vector<uint32_t> rgb;
    for (size_t column = 0; strip && column < CGImageGetWidth(strip); column++) {
        rgb.push_back(VibeStripRGBAt(strip, column));
    }
    return rgb;
}

// The height reach would mix neighboring bands into identical colors. The
// tent is 1/256 of the track foot to foot: four chunks here, two bars at
// 512 bars, so a bar's own band leads with a quarter of each neighbor's.
- (void)testSpectrumColorsEachBarByItsOwnBandDownToTheTent {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    theme.flatFill = YES;
    std::vector<uint32_t> rgb = [self spectrumStripRGBForAlternationPeriod:2 scale:1 theme:theme];
    XCTAssertEqual(rgb.size(), 1024u / 2);
    if (rgb.size() == 512) {
        XCTAssertGreaterThan(rgb[256] >> 16 & 0xff, rgb[256] & 0xff, @"red leads a low bar");
        XCTAssertGreaterThan(rgb[257] & 0xff, rgb[257] >> 16 & 0xff, @"blue leads a high bar");
        XCTAssertNotEqual(rgb[256], VibeSRGBOf(theme.spectrumColors[0]), @"a quarter of each neighbor");
        XCTAssertNotEqual(rgb[257], VibeSRGBOf(theme.spectrumColors[2]));
    }
}

// Bars finer than the tent read the tent about their centers, so bins
// alternating every bin color every one-bin bar the same.
- (void)testSpectrumColorsBarsFinerThanTheTentByTheTent {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
    theme.flatFill = YES;
    std::vector<uint32_t> rgb = [self spectrumStripRGBForAlternationPeriod:1 scale:2 theme:theme];
    XCTAssertEqual(rgb.size(), 1024u);
    if (rgb.size() == 1024) {
        XCTAssertEqual(rgb[512], rgb[513]);
        XCTAssertNotEqual(rgb[512], VibeSRGBOf(theme.spectrumColors[0]));
        XCTAssertNotEqual(rgb[512], VibeSRGBOf(theme.spectrumColors[2]));
    }
}

- (void)testSpectrumOutlineIsTheTallestBand {
    std::array<float, 3> bands = {1, 0.01f, 0.0001f};
    auto waveform = VibeThreeBandTestWaveform(bands);
    WaveformRenderer *renderer = [self rendererForStyle:@"spectrum"];
    [renderer updateWaveform:renderer.parentLayer.bounds progress:0.5 waveform:waveform.get()];
    [renderer settleMorphImmediately];
    CAShapeLayer *outline = (CAShapeLayer *)VibeThreeBandHost(renderer).sublayers.firstObject.mask;
    XCTAssertEqual(CGPathGetPathBoundingBox(outline.path).size.height,
                   [self threeBandLayerHeightsForBands:bands][0]);
}

@end
