#import <XCTest/XCTest.h>

#import "AudioWaveform.h"
#import "WaveformMorphEngine.h"
#import "WaveformRendererRegistry.h"
#import "DetailedAudioWaveformRenderer.h"
#import "ThreeBandWaveformRenderer.h"
#import "AppSettings.h"
#import "VibeStrings.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <numeric>
#include <vector>

@interface AudioWaveformTests : XCTestCase
@end

@implementation AudioWaveformTests {
    // 64 chunks, chunk i = (min -i, max +i): the index is recoverable from
    // either extreme, so a combined column reports which source chunks it
    // actually covered.
    std::vector<AudioWaveformCacheChunk> _source;
}

- (void)setUp {
    _source.assign(64, AudioWaveformCacheChunk());
    for (NSUInteger i = 0; i < 64; i++) {
        _source[i].set(-(float)i, (float)i);
    }
}

- (AudioWaveform *)waveform {
    return new AudioWaveform(_source.size(), _source.data());
}

// Normalize's reference as a fill reads it: off the energy columns it drew.
static float VibeTestFullScaleRMS(AudioWaveform *waveform, BOOL normalize, NSUInteger columns) {
    std::vector<float> meanSquares(columns);
    waveform->getBarMeanSquares(columns, 0, meanSquares.data(), nullptr);
    return VibeWaveformFullScaleRMSForColumns(waveform, normalize, meanSquares.data(), columns);
}

- (AudioWaveformRenderer *)rendererForStyle:(NSString *)identifier {
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

// Grounded, each bar keeps its height and stands on the band's foot.
- (void)testGroundedBarsStandOnTheBaselineAtTheirCenteredHeight {
    // Quiet, so no style's centered bar reaches the band's foot already.
    AudioWaveformCacheChunk chunk;
    chunk.set(-0.3f, 0.5f, 0.01f, 1);
    AudioWaveform waveform(1, &chunk);
    for (NSString *style in @[@"detailed", @"oversampling_detailed_x4", @"basic", @"cupertino"]) {
        CGRect boxes[2];
        for (BOOL centered : {YES, NO}) {
            AudioWaveformRenderer *renderer = [self rendererForStyle:style];
            renderer.centered = centered;
            CALayer *host = renderer.parentLayer;
            [renderer updateWaveform:host.bounds progress:0.5 waveform:&waveform];
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
        AudioWaveformRenderer *renderer = [self rendererForStyle:style];
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

// Grounded, Cupertino's bars stand as Basic's, so they take Basic's ramp
// rather than the fade mirrored about the midline.
- (void)testGroundedCupertinoTakesBasicsRamp {
    VibeColor *color = [VibeColor colorWithWhite:1 alpha:0.8];
    DetailedAudioWaveformRenderer *cupertino = (DetailedAudioWaveformRenderer *)[self rendererForStyle:@"cupertino"];
    DetailedAudioWaveformRenderer *basic = (DetailedAudioWaveformRenderer *)[self rendererForStyle:@"basic"];
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
    AudioWaveformRenderer *renderer = [self rendererForStyle:@"cupertino_basic"];
    CALayer *host = renderer.parentLayer;
    CALayer *pill = host.sublayers.firstObject;
    CALayer *fill = pill.sublayers.firstObject;
    AudioWaveform waveform;
    [renderer updateWaveform:host.bounds progress:0.25 waveform:&waveform];
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
    [renderer updateWaveform:host.bounds progress:0.25 waveform:&waveform];
    XCTAssertEqual(pill.bounds.size.height, 32);
    host.bounds = CGRectMake(0, 0, 512, 20);
    [renderer updateWaveform:host.bounds progress:0.25 waveform:&waveform];
    XCTAssertTrue(CGRectContainsRect(host.bounds, pill.frame));
    [renderer updateWaveform:host.bounds progress:0 waveform:nullptr];
    renderer.barWidthScale = 0.5;
    XCTAssertTrue(pill.hidden);
}

- (void)testBarWidthRebuildsLiveGeometryWithoutChangingCount {
    AudioWaveformCacheChunk chunk;
    chunk.set(-0.5f, 0.5f, 0.25f, 1);
    AudioWaveform waveform(1, &chunk);
    for (NSString *style in @[@"basic", @"cupertino", @"sonic_cirrus", @"wiggle_centered"]) {
        AudioWaveformRenderer *renderer = [self rendererForStyle:style];
        CALayer *host = renderer.parentLayer;
        BOOL sonic = [style isEqualToString:@"sonic_cirrus"];
        BOOL wiggle = [style hasPrefix:@"wiggle"];
        DetailedAudioWaveformRenderer *detailed = sonic ? nil : (DetailedAudioWaveformRenderer *)renderer;
        for (CGFloat density : {0.5, 1.0, 2.0}) {
            renderer.barDensity = density;
            renderer.barWidthScale = 1;
            [renderer updateWaveform:host.bounds progress:0.5 waveform:&waveform];
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
        AudioWaveformCacheChunk chunk;
        chunk.set(-rms, rms, rms * rms, 1);
        AudioWaveform waveform(1, &chunk);
        float plain = VibeTestFullScaleRMS(&waveform, NO, 1024);
        float normalized = VibeTestFullScaleRMS(&waveform, YES, 1024);
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

- (void)testEveryDetailedVariantNormalizesAtItsDrawnEnergyResolution {
    std::vector<AudioWaveformCacheChunk> chunks(8192);
    for (auto &chunk : chunks) chunk.set(-0.1f, 0.1f, 0.01f, 1);
    chunks[4095].set(-0.8f, 0.8f, 0.64f, 1); // a transient inside a quieter averaged section
    AudioWaveform waveform(chunks.size(), chunks.data());
    for (NSString *identifier in [WaveformRendererRegistry availableIdentifiers]) {
        // These two draw individual layers; the next test covers their geometry.
        // The band styles draw three levels a bar, which their own tests cover.
        if ([identifier isEqualToString:@"sonic_cirrus"] || [identifier isEqualToString:@"cupertino_basic"] ||
            [WaveformRendererRegistry readsBandsForIdentifier:identifier]) continue;
        DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)[self rendererForStyle:identifier];
        XCTAssertTrue([renderer isKindOfClass:DetailedAudioWaveformRenderer.class], @"%@", identifier);
        for (CGFloat width : {257.0, 512.0, 773.0}) {
            NSUInteger count = [renderer numBarsForWidth:width];
            std::vector<float> plain(count * 2), normalized(count * 2);
            for (float gain : {-12.0f, 0.0f, 12.0f}) {
                renderer.gainDB = gain;
                renderer.normalizesLevels = NO;
                [renderer fillEnvelope:plain.data() barCount:count waveform:&waveform];
                renderer.normalizesLevels = YES;
                [renderer fillEnvelope:normalized.data() barCount:count waveform:&waveform];
                for (NSUInteger i = 0; i < count; i++) {
                    XCTAssertLessThanOrEqual(normalized[i * 2], plain[i * 2], @"%@", identifier);
                    XCTAssertGreaterThanOrEqual(normalized[i * 2 + 1], plain[i * 2 + 1], @"%@", identifier);
                }
                if (gain == 0) {
                    XCTAssertEqualWithAccuracy(*std::max_element(normalized.begin(), normalized.end()), 1, 1e-6, @"%@", identifier);
                }
            }
        }
    }
}

// Past 1,024 bars a column's bars need not cover its chunks. A transient one
// of them misses must still set the column's peak, or the quiet bars beside it
// are scaled up to its level.
- (void)testDetailedQuietBarsBesideATransientStayQuiet {
    std::vector<AudioWaveformCacheChunk> chunks(8192);
    for (auto &chunk : chunks) chunk.set(-0.01f, 0.01f, 0.0001f, 1);
    chunks[816].set(-0.5f, 0.5f, 0.25f, 1);
    AudioWaveform waveform(chunks.size(), chunks.data());
    DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)[self rendererForStyle:@"detailed"];
    for (CGFloat width : {930.0, 931.0, 1200.0}) {
        NSUInteger count = [renderer numBarsForWidth:width];
        XCTAssertGreaterThan(count, kVibeWaveformEnergyColumns);
        std::vector<float> envelope(count * 2);
        [renderer fillEnvelope:envelope.data() barCount:count waveform:&waveform];
        for (NSUInteger i = 0; i < count; i++) {
            if (waveform.getChunkAtIndex(i, count).getMax() < 0.1f) {
                XCTAssertLessThan(envelope[i * 2 + 1], 0.05f, @"width %g bar %lu", width, i);
            }
        }
    }
}

// A bar straddling into the next column's transient widens only its own
// reference: the bars beside it, which hold none of it, keep their height.
- (void)testDetailedBarsBesideAStraddlingTransientKeepTheirHeight {
    std::vector<AudioWaveformCacheChunk> chunks(8192);
    for (auto &chunk : chunks) chunk.set(-0.1f, 0.1f, 0.01f, 1);
    std::vector<AudioWaveformCacheChunk> steady = chunks;
    chunks[816].set(-0.9f, 0.9f, 0.81f, 1);
    AudioWaveform waveform(chunks.size(), chunks.data()), background(steady.size(), steady.data());
    DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)[self rendererForStyle:@"detailed"];
    for (CGFloat width : {930.0, 931.0, 1200.0}) {
        NSUInteger count = [renderer numBarsForWidth:width];
        std::vector<float> envelope(count * 2), plain(count * 2);
        [renderer fillEnvelope:envelope.data() barCount:count waveform:&waveform];
        [renderer fillEnvelope:plain.data() barCount:count waveform:&background];
        for (NSUInteger i = 0; i < count; i++) {
            NSUInteger column = VibeWaveformEnergyColumnIndexForBar(i, count);
            BOOL touched = waveform.getChunkAtIndex(i, count).getMax() > 0.5f ||
                    waveform.getChunkAtIndex(column, kVibeWaveformEnergyColumns).getMax() > 0.5f;
            if (!touched) {
                XCTAssertEqualWithAccuracy(envelope[i * 2 + 1], plain[i * 2 + 1], 1e-3, @"width %g bar %lu", width, i);
            }
        }
    }
}

- (void)testLayerStylesOnlyGrowUnderNormalization {
    std::vector<AudioWaveformCacheChunk> chunks(1024);
    for (auto &chunk : chunks) chunk.set(-0.1f, 0.1f, 0.01f, 1);
    chunks[511].set(-0.8f, 0.8f, 0.64f, 1);
    AudioWaveform waveform(chunks.size(), chunks.data());
    for (NSString *identifier in @[@"sonic_cirrus", @"cupertino_basic"]) {
        AudioWaveformRenderer *renderer = [self rendererForStyle:identifier];
        CALayer *host = renderer.parentLayer;
        for (CGFloat width : {257.0, 512.0, 773.0}) {
            host.bounds = CGRectMake(0, 0, width, 80);
            for (float gain : {-12.0f, 0.0f, 12.0f}) {
                renderer.gainDB = gain;
                renderer.normalizesLevels = NO;
                [renderer updateWaveform:host.bounds progress:0.5 waveform:&waveform];
                [renderer settleMorphImmediately];
                std::vector<CGFloat> plain;
                for (CALayer *layer in host.sublayers) plain.push_back(layer.bounds.size.height);
                renderer.normalizesLevels = YES;
                [renderer updateWaveform:host.bounds progress:0.5 waveform:&waveform];
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
                    // Cupertino Basic is a fixed 9pt pill independent of audio.
                    XCTAssertEqualWithAccuracy(maximum, [identifier isEqualToString:@"sonic_cirrus"] ? 42 : 9, 1e-6);
                }
            }
        }
    }
}

// Wiggle MC is Wiggle with Centered off: its identifier is gone, and only the
// migrations read it (AppThemeTests).
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
        DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)[self rendererForStyle:identifier];
        BOOL wiggle = ![identifier isEqualToString:@"detailed"];
        XCTAssertEqual(renderer.class, DetailedAudioWaveformRenderer.class);
        XCTAssertEqual([renderer numBarsForWidth:512], wiggle ? 64u : 1024u);
        renderer.samplingWidth = 512;
        XCTAssertEqual([renderer numBarsForWidth:2048], wiggle ? 64u : 4096u,
                       @"Zoom must preserve Wiggle's loops without reducing Detailed's resolution");
        renderer.samplingWidth = 768;
        XCTAssertEqual([renderer numBarsForWidth:2048], wiggle ? 96u : 4096u);
    }
}

- (void)testWiggleHighlightsWholeLoopsWithoutQuantizingThePlayedFill {
    DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)[self rendererForStyle:@"wiggle_centered"];
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
    AudioWaveformCacheChunk quiet;
    quiet.set(-0.014f, 0.014f, 0.000196f, 1);
    AudioWaveform waveform(1, &quiet);
    for (BOOL centered : {YES, NO}) {
        AudioWaveformRenderer *renderer = [self rendererForStyle:@"wiggle_centered"];
        renderer.centered = centered;
        CALayer *host = renderer.parentLayer;
        [renderer updateWaveform:host.bounds progress:0 waveform:&waveform];
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
    AudioWaveformCacheChunk quiet;
    quiet.set(-0.1f, 0.1f, 0.01f * 4, 4);
    AudioWaveform loading;
    for (NSUInteger i = 0; i < loading.getNumChunks(); i++) {
        loading.setChunkAtIndex(quiet, i);
    }
    AudioWaveform snapshot(loading);
    XCTAssertFalse(snapshot.isComplete());
    XCTAssertEqual(VibeTestFullScaleRMS(&snapshot, YES, 1024), kVibeWaveformFullScaleRMS);

    loading.markComplete();
    AudioWaveform whole(loading);
    XCTAssertTrue(whole.isComplete());
    XCTAssertEqualWithAccuracy(VibeTestFullScaleRMS(&whole, YES, 1024), 0.1f, 1e-6);

    // An archive is only written complete.
    AudioWaveform archived(1, &quiet);
    XCTAssertTrue(archived.isComplete());
}

// The edge is the first chunk with no frames, and a complete waveform is whole
// even where its decode ended a chunk short.
- (void)testDecodedFractionIsTheFirstUnfilledChunk {
    AudioWaveform loading;
    NSUInteger count = loading.getNumChunks();
    XCTAssertEqual(loading.getDecodedFraction(), 0);
    AudioWaveformCacheChunk silent;
    silent.set(0, 0, 0, 4);
    for (NSUInteger i = 0; i < count / 4; i++) {
        loading.setChunkAtIndex(silent, i);
    }
    XCTAssertEqual(loading.getDecodedFraction(), 0.25);
    loading.markComplete();
    XCTAssertEqual(loading.getDecodedFraction(), 1);
}

#pragma mark - 3-Band

// The painter's layers, in order: low, mid, high, low+mid, low+high, mid+high,
// all three.
static const NSUInteger kThreeBandLayers = 7;

// 1,024 identical chunks with these band mean squares, under a broadband RMS
// of 0.1.
static AudioWaveform VibeThreeBandTestWaveform(std::array<float, 3> bands) {
    std::vector<AudioWaveformCacheChunk> chunks(1024);
    std::vector<float> bandSums;
    for (auto &chunk : chunks) {
        chunk.set(-0.1f, 0.1f, 0.01f, 1);
        bandSums.insert(bandSums.end(), bands.begin(), bands.end());
    }
    return AudioWaveform(chunks.size(), chunks.data(), bandSums.data());
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
static CALayer *VibeThreeBandHost(AudioWaveformRenderer *renderer) {
    return renderer.parentLayer.sublayers.firstObject.sublayers.firstObject;
}

static NSArray<CAShapeLayer *> *VibeThreeBandLayers(AudioWaveformRenderer *renderer) {
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
    AudioWaveform waveform = VibeThreeBandTestWaveform(bands);
    AudioWaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    renderer.normalizesLevels = normalize;
    CALayer *host = renderer.parentLayer;
    [renderer updateWaveform:host.bounds progress:0.5 waveform:hasWaveform ? &waveform : nullptr];
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
    AudioWaveform waveform = VibeThreeBandTestWaveform({1, 0.01f, 0.0001f});
    std::vector<CGRect> boxes[2];
    for (BOOL centered : {YES, NO}) {
        AudioWaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
        renderer.centered = centered;
        [renderer updateWaveform:renderer.parentLayer.bounds progress:0.5 waveform:&waveform];
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

// The bars' levels, low to high, as 3-Band draws them across this width.
- (std::vector<float>)threeBandLevelsForWaveform:(AudioWaveform *)waveform width:(CGFloat)width {
    AudioWaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    CGRect bounds = renderer.parentLayer.bounds;
    renderer.parentLayer.bounds = CGRectMake(0, 0, width, bounds.size.height);
    NSData *samples = [renderer envelopeSamplesForWaveform:waveform];
    const float *levels = (const float *)samples.bytes;
    return std::vector<float>(levels, levels + samples.length / sizeof(float));
}

// A bar a point, up to the waveform's chunks.
- (void)testThreeBandBarsFollowTheDrawnWidth {
    AudioWaveform waveform = VibeThreeBandTestWaveform({1, 0.01f, 0.0001f});
    for (std::array<CGFloat, 2> widthAndBars : {std::array<CGFloat, 2>{512, 512}, {3000, 3000}, {20000, 8192}}) {
        XCTAssertEqual([self threeBandLevelsForWaveform:&waveform width:widthAndBars[0]].size(),
                       (NSUInteger)widthAndBars[1] * kAudioWaveformBandCount);
    }
}

// Zoomed in, the bars resolve a kick every eight chunks, which the 1/1024
// floor would average into one steady column.
- (void)testThreeBandZoomResolvesKicksTheFloorAverages {
    std::vector<AudioWaveformCacheChunk> chunks(8192);
    std::vector<float> bandSums;
    for (NSUInteger i = 0; i < chunks.size(); i++) {
        chunks[i].set(-0.1f, 0.1f, 0.01f, 1);
        float low = i % 8 < 2 ? 0.04f : 0.0001f;
        bandSums.insert(bandSums.end(), {low, 0.0001f, 0.00001f});
    }
    AudioWaveform waveform(chunks.size(), chunks.data(), bandSums.data());
    auto lowLevels = [&](CGFloat width) {
        std::vector<float> levels = [self threeBandLevelsForWaveform:&waveform width:width];
        std::vector<float> low;
        for (NSUInteger i = 0; i < levels.size(); i += kAudioWaveformBandCount) low.push_back(levels[i]);
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

// Each layer is one outline through the bars, never a shape per bar.
- (void)testThreeBandDrawsOneOutlinePerLayer {
    AudioWaveform waveform = VibeThreeBandTestWaveform({1, 0.01f, 0.0001f});
    AudioWaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    [renderer updateWaveform:renderer.parentLayer.bounds progress:0.5 waveform:&waveform];
    [renderer settleMorphImmediately];
    for (CAShapeLayer *layer in VibeThreeBandLayers(renderer)) {
        XCTAssertEqual(VibeSubpathCount(layer.path), 1u);
    }
}

// The band fills are the theme's, live and baked alike: the bake's core,
// low+mid ring and low band's own, read at the bitmap's center column.
- (void)testThreeBandPaintsEachRingInTheThemesBandColor {
    std::array<float, 3> levels = {1, 0.01f, 0.0001f};
    AudioWaveform waveform = VibeThreeBandTestWaveform(levels);
    AudioWaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
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
                                                 samples:[renderer envelopeSamplesForWaveform:&waveform]];
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
    AudioWaveform waveform = VibeThreeBandTestWaveform({1, 0.01f, 0.0001f});
    AudioWaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
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
                                                     samples:[renderer envelopeSamplesForWaveform:&waveform]];
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

// The playhead splits the mask over one set of band layers.
- (void)testThreeBandProgressSplitsTheSides {
    AudioWaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    CGFloat width = renderer.parentLayer.bounds.size.width;
    [renderer updateProgress:0.25 waveform:nullptr];
    NSArray<CALayer *> *sides = VibeThreeBandHost(renderer).mask.sublayers;
    XCTAssertEqual(CGRectGetMaxX(sides[0].frame), width * 0.25);
    XCTAssertEqual(CGRectGetMinX(sides[1].frame), width * 0.25);
    XCTAssertEqual(CGRectGetMaxX(sides[1].frame), width);
    XCTAssertEqual(VibeThreeBandLayers(renderer).count, kThreeBandLayers);
}

// The hover slice's outline is the tallest band, built only while it shows.
- (void)testThreeBandBuildsItsHoverOutlineOnlyWhileShown {
    std::array<float, 3> bands = {1, 0.01f, 0.0001f};
    AudioWaveform waveform = VibeThreeBandTestWaveform(bands);
    AudioWaveformRenderer *renderer = [self rendererForStyle:@"three_band"];
    CALayer *host = renderer.parentLayer;
    [renderer updateWaveform:host.bounds progress:0.5 waveform:&waveform];
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

// 3-Band and Spectrum read the bands. Only 3-Band paints the band palette.
- (void)testOnlyTheBandStylesReadTheBands {
    for (NSString *identifier in WaveformRendererRegistry.availableIdentifiers) {
        BOOL spectrum = [identifier isEqualToString:@"spectrum"];
        XCTAssertEqual([WaveformRendererRegistry readsBandsForIdentifier:identifier],
                       spectrum || [identifier isEqualToString:@"three_band"], @"%@", identifier);
        XCTAssertEqual([WaveformRendererRegistry usesBandPaletteForIdentifier:identifier],
                       [identifier isEqualToString:@"three_band"], @"%@", identifier);
    }
    XCTAssertFalse([WaveformRendererRegistry readsBandsForIdentifier:nil]);
    XCTAssertFalse([WaveformRendererRegistry readsBandsForIdentifier:@"missing-style"]);
    XCTAssertFalse([WaveformRendererRegistry usesBandPaletteForIdentifier:nil]);
}

// A theme's swatch shows the band styles' own colors and every other style's
// played color, an unregistered one included.
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
    NSColor *converted = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return (uint32_t)lround(converted.redComponent * 255) << 16 | (uint32_t)lround(converted.greenComponent * 255) << 8
           | (uint32_t)lround(converted.blueComponent * 255);
}

// The live strip's pixel at column, as 0xRRGGBB: the strip is R, G, B, X in
// memory.
static uint32_t VibeStripRGBAt(CGImageRef strip, size_t column) {
    NSData *pixels = CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(strip)));
    const uint8_t *p = (const uint8_t *)pixels.bytes + column * 4;
    return (uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2];
}

// Spectrum settled on these bands under a flat theme: its bake's center pixel,
// after checking the live tree is one strip under one outline whose center
// agrees with the bake.
- (uint32_t)spectrumCenterRGBForBands:(std::array<float, 3>)bands theme:(WaveformTheme *)theme {
    AudioWaveform waveform = VibeThreeBandTestWaveform(bands);
    AudioWaveformRenderer *renderer = [self rendererForStyle:@"spectrum"];
    renderer.theme = theme;
    [renderer updateColors:YES];
    [renderer updateWaveform:renderer.parentLayer.bounds progress:0.5 waveform:&waveform];
    [renderer settleMorphImmediately];
    NSArray<CALayer *> *fills = VibeThreeBandHost(renderer).sublayers;
    XCTAssertEqual(fills.count, 1u, @"one strip in place of the band layers");
    CGImageRef strip = (__bridge CGImageRef)fills.firstObject.contents;
    XCTAssertTrue(strip != NULL);
    XCTAssertEqual(CGImageGetWidth(strip), 512u, @"a pixel per backing pixel");
    XCTAssertEqual(VibeSubpathCount(((CAShapeLayer *)fills.firstObject.mask).path), 1u);
    CGSize size = renderer.parentLayer.bounds.size;
    CGImageRef image = [renderer newEnvelopeImageForSize:size scale:1
                                                 samples:[renderer envelopeSamplesForWaveform:&waveform]];
    XCTAssertTrue(image != NULL);
    uint32_t baked = image ? VibeRGBAt(image, CGImageGetHeight(image) / 2, 256) : 0;
    CGImageRelease(image);
    if (strip) {
        XCTAssertEqual(VibeStripRGBAt(strip, 256), baked, @"the live strip and the bake agree");
    }
    return baked;
}

// A lone band is its primary. Low with high is a purple neither primary is,
// which no single tone makes.
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
    uint32_t purple = [self spectrumCenterRGBForBands:{1, 0, 1} theme:theme];
    uint32_t red = purple >> 16 & 0xff, green = purple >> 8 & 0xff, blue = purple & 0xff;
    XCTAssertGreaterThan(red, green);
    XCTAssertGreaterThan(blue, green);
    XCTAssertNotEqual(purple, low);
    XCTAssertNotEqual(purple, high);
}

// The outline is the tallest band, as 3-Band's outer edge is.
- (void)testSpectrumOutlineIsTheTallestBand {
    std::array<float, 3> bands = {1, 0.01f, 0.0001f};
    AudioWaveform waveform = VibeThreeBandTestWaveform(bands);
    AudioWaveformRenderer *renderer = [self rendererForStyle:@"spectrum"];
    [renderer updateWaveform:renderer.parentLayer.bounds progress:0.5 waveform:&waveform];
    [renderer settleMorphImmediately];
    CAShapeLayer *outline = (CAShapeLayer *)VibeThreeBandHost(renderer).sublayers.firstObject.mask;
    XCTAssertEqual(CGPathGetPathBoundingBox(outline.path).size.height,
                   [self threeBandLayerHeightsForBands:bands][0]);
}

#pragma mark - getBarMeanSquares

// Chunk i carries mean square i, and bands i, 2i and 3i, over one frame.
static AudioWaveform VibeRampWaveform(NSUInteger count) {
    std::vector<AudioWaveformCacheChunk> chunks(count);
    std::vector<float> bands;
    for (NSUInteger i = 0; i < count; i++) {
        chunks[i].set(0, 0, (float)i, 1);
        bands.insert(bands.end(), {(float)i, (float)i * 2, (float)i * 3});
    }
    return AudioWaveform(chunks.size(), chunks.data(), bands.data());
}

// Without reach a bar's window is the bar, so a ramp reads its own value at
// the bar's center, in the mix and in every band; with or without, it never
// runs backwards.
- (void)testBarMeanSquaresReadARampAtEachBarsCenter {
    AudioWaveform w = VibeRampWaveform(64);
    for (NSUInteger size : {(NSUInteger)64, (NSUInteger)32, (NSUInteger)8}) {
        std::vector<float> mix(size), bands(size * kAudioWaveformBandCount);
        w.getBarMeanSquares(size, 0, mix.data(), bands.data());
        for (NSUInteger i = 0; i < size; i++) {
            float center = ((float)i + 0.5f) * 64 / (float)size - 0.5f;
            XCTAssertEqualWithAccuracy(mix[i], center, 1e-4, @"size %lu bar %lu", size, i);
            for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
                XCTAssertEqualWithAccuracy(bands[i * kAudioWaveformBandCount + b], center * (b + 1), 1e-3,
                                           @"size %lu bar %lu band %lu", size, i, b);
            }
        }
    }
    for (float reach : {0.0f, 0.5f, 1.0f}) {
        for (NSUInteger size = 1; size <= 200; size++) {
            std::vector<float> mix(size);
            w.getBarMeanSquares(size, reach, mix.data(), nullptr);
            for (NSUInteger i = 0; i < size; i++) {
                XCTAssertTrue(mix[i] >= 0 && mix[i] <= 63 + 1e-3f, @"reach %g size %lu bar %lu", reach, size, i);
                if (i > 0) {
                    XCTAssertGreaterThanOrEqual(mix[i], mix[i - 1] - 1e-4f, @"reach %g size %lu bar %lu", reach, size, i);
                }
            }
        }
    }
}

// The frames are windowed as the sums are, so a steady level reads as itself
// at every width and reach, the bars whose windows slide off the track
// included, and a load still streaming is the mean of the frames it has: its
// front bar is not dragged toward the silence past it.
- (void)testBarMeanSquaresAreTheMeanOfTheFramesTheWindowCovers {
    std::vector<AudioWaveformCacheChunk> chunks(64);
    for (NSUInteger i = 0; i < 32; i++) chunks[i].set(-0.5f, 0.5f, 0.25f * 4, 4);
    AudioWaveform half(chunks.size(), chunks.data());
    for (NSUInteger i = 32; i < 64; i++) chunks[i].set(-0.5f, 0.5f, 0.25f * 4, 4);
    AudioWaveform whole(chunks.size(), chunks.data());
    for (float reach : {0.0f, 1.0f}) {
        for (NSUInteger size = 1; size <= 200; size++) {
            std::vector<float> loaded(size), level(size), bands(size * kAudioWaveformBandCount, 1);
            whole.getBarMeanSquares(size, reach, level.data(), bands.data());
            half.getBarMeanSquares(size, reach, loaded.data(), nullptr);
            for (NSUInteger i = 0; i < size; i++) {
                XCTAssertEqualWithAccuracy(level[i], 0.25f, 1e-5, @"size %lu bar %lu", size, i);
                XCTAssertTrue(loaded[i] == 0 || fabsf(loaded[i] - 0.25f) < 1e-5f, @"size %lu bar %lu", size, i);
                XCTAssertEqual(bands[i * kAudioWaveformBandCount], 0, @"no bands read as silence");
            }
            XCTAssertEqualWithAccuracy(loaded[0], 0.25f, 1e-5, @"size %lu", size);
            if (size >= 4) XCTAssertEqual(loaded[size - 1], 0, @"size %lu", size);
        }
    }
    AudioWaveform empty(0, nullptr);
    float untouched = 7;
    empty.getBarMeanSquares(1, 1, &untouched, nullptr);
    XCTAssertEqual(untouched, 0);
}

// What the reach is for. A kick in two chunks of every ten, drawn at about a
// thousand bars: a bar is 0.8 of a beat, so a bar with hard edges holds a
// whole kick, part of one or two parts, and the bars beat against the kicks
// in a pattern that runs along the waveform as a resize moves the edges. With
// reach every bar finds a window holding one kick whole, at its full height.
- (void)testReachHoldsBarsStillAgainstABeatAboutABarLong {
    std::vector<AudioWaveformCacheChunk> chunks(8192);
    for (NSUInteger i = 0; i < chunks.size(); i++) {
        chunks[i].set(-1, 1, i % 10 < 2 ? 1.0f : 0.01f, 1);
    }
    AudioWaveform w(chunks.size(), chunks.data());
    auto spread = [](const std::vector<float> &bars) {
        auto [low, high] = std::minmax_element(bars.begin() + 1, bars.end() - 1);
        float mean = std::accumulate(bars.begin() + 1, bars.end() - 1, 0.0f) / (float)(bars.size() - 2);
        return (*high - *low) / mean;
    };
    for (NSUInteger size : {(NSUInteger)1000, (NSUInteger)1001, (NSUInteger)1010}) {
        std::vector<float> still(size), hard(size);
        w.getBarMeanSquares(size, 1, still.data(), nullptr);
        w.getBarMeanSquares(size, 0, hard.data(), nullptr);
        XCTAssertGreaterThan(spread(hard), 1.0f, @"size %lu", size);
        XCTAssertLessThan(spread(still), 0.05f, @"size %lu", size);
        float oneKick = (2 + ((float)chunks.size() / size - 2) * 0.01f) / ((float)chunks.size() / size);
        XCTAssertEqualWithAccuracy(still[size / 2], oneKick, oneKick * 0.01f, @"size %lu", size);
    }
}

// The reach fades out as the bars get short: full up to the given count,
// none from twice that.
- (void)testWindowReachFadesOutAsBarsGetShort {
    XCTAssertEqual(VibeWaveformWindowReach(2, 512), 1);
    XCTAssertEqual(VibeWaveformWindowReach(512, 512), 1);
    XCTAssertEqual(VibeWaveformWindowReach(768, 512), 0.5f);
    XCTAssertEqual(VibeWaveformWindowReach(1024, 512), 0);
    XCTAssertEqual(VibeWaveformWindowReach(8192, 512), 0);
}

#pragma mark - getChunkAtIndex

- (void)testRequestingTheNativeChunkCountReturnsChunksVerbatim {
    AudioWaveform *w = [self waveform];
    for (NSUInteger i = 0; i < 64; i++) {
        AudioWaveformCacheChunk c = w->getChunkAtIndex(i, 64);
        XCTAssertEqual(c.getMin(), -(float)i);
        XCTAssertEqual(c.getMax(), (float)i);
    }
    delete w;
}

- (void)testColumnsCombineTheirWholeRange {
    // Even columns of 8 and 16 chunks, and uneven ones of 12.8 and 21.3,
    // against an independent scalar reduction.
    AudioWaveform *w = [self waveform];
    for (NSUInteger size : {(NSUInteger)8, (NSUInteger)4, (NSUInteger)5, (NSUInteger)3}) {
        for (NSUInteger i = 0; i < size; i++) {
            NSUInteger end = 64 * (i + 1) / size;
            AudioWaveformCacheChunk c = w->getChunkAtIndex(i, size);
            XCTAssertEqual(c.getMin(), -(float)(end - 1), @"size %lu column %lu", size, i);
            XCTAssertEqual(c.getMax(), (float)(end - 1));
        }
    }
    delete w;
}

- (void)testBandMeanSquaresReadEachChunk {
    AudioWaveform w = VibeRampWaveform(64);
    float meanSquares[kAudioWaveformBandCount];
    for (NSUInteger i = 0; i < 64; i++) {
        w.getBandMeanSquares(i, meanSquares);
        for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
            XCTAssertEqual(meanSquares[b], (float)(i * (b + 1)), @"chunk %lu band %lu", i, b);
        }
    }
    AudioWaveform copy(w);
    copy.getBandMeanSquares(63, meanSquares);
    XCTAssertEqual(meanSquares[2], 189, @"a copy carries the bands");

    // Without bands every read is silence and every write a no-op.
    AudioWaveform plain(_source.size(), _source.data());
    XCTAssertFalse(plain.hasBands());
    const float sums[kAudioWaveformBandCount] = {1, 2, 3};
    plain.setBandSumSquaresAtIndex(sums, 0);
    plain.copyChunk(0, 1);
    plain.getBandMeanSquares(0, meanSquares);
    XCTAssertEqual(meanSquares[0] + meanSquares[1] + meanSquares[2], 0);
    XCTAssertFalse(AudioWaveform(plain).hasBands());
}

- (void)testColumnsTileTheSourceWithoutSkippingChunks {
    // Why columns are [start(i), start(i+1)) rather than a floored fixed width:
    // at a fractional ratio the latter skips source chunks, and a transient
    // there vanishes at that view width.
    for (NSUInteger size = 1; size <= 64; size++) {
        for (NSUInteger spikeAt : {(NSUInteger)0, (NSUInteger)37, (NSUInteger)63}) {
            std::vector<AudioWaveformCacheChunk> chunks(64, AudioWaveformCacheChunk());
            chunks[spikeAt].set(-1.0f, 1.0f);
            AudioWaveform *w = new AudioWaveform(chunks.size(), chunks.data());

            float widest = 0;
            for (NSUInteger i = 0; i < size; i++) {
                widest = std::max(widest, w->getChunkAtIndex(i, size).getMax());
            }
            XCTAssertEqual(widest, 1.0f,
                           @"spike at chunk %lu lost at width %lu", spikeAt, size);
            delete w;
        }
    }
}

- (void)testOversamplingBeyondTheSourceRepeatsRatherThanReadingGarbage {
    // The x2/x4/x8 styles deliberately ask for more columns than there are
    // chunks; every column must still land inside the buffer.
    AudioWaveform *w = [self waveform];
    for (NSUInteger i = 0; i < 256; i++) {
        AudioWaveformCacheChunk c = w->getChunkAtIndex(i, 256);
        XCTAssertTrue(std::isfinite(c.getMin()) && std::isfinite(c.getMax()));
        XCTAssertLessThanOrEqual(c.getMax(), 63.0f);
        XCTAssertGreaterThanOrEqual(c.getMin(), -63.0f);
    }
    delete w;
}

- (void)testOutOfRangeIndexReturnsAnEmptyChunk {
    AudioWaveform *w = [self waveform];
    AudioWaveformCacheChunk c = w->getChunkAtIndex(8, 8);
    XCTAssertEqual(c.getMin(), 0.0f);
    XCTAssertEqual(c.getMax(), 0.0f);
    delete w;
}

- (void)testWaveformBuiltFromNullChunksReadsAsEmpty {
    // The failed-alloc / null-source guard.
    AudioWaveform *w = new AudioWaveform(64, nullptr);
    XCTAssertEqual(w->getNumChunks(), (NSUInteger)0);
    AudioWaveformCacheChunk c = w->getChunkAtIndex(0, 8);
    XCTAssertEqual(c.getMin(), 0.0f);
    XCTAssertEqual(c.getMax(), 0.0f);
    delete w;
}

- (void)testDefaultWaveformIsZeroedAtFullChunkCount {
    AudioWaveform *w = new AudioWaveform();
    XCTAssertGreaterThan(w->getNumChunks(), (NSUInteger)0);
    XCTAssertEqual(w->getNumBytes(), w->getNumChunks() * sizeof(AudioWaveformCacheChunk));
    XCTAssertFalse(w->hasBands(), @"only a decode asked for the bands holds them");
    XCTAssertEqual(w->getNumBandBytes(), 0u);
    XCTAssertEqual(w->getChunkAtIndex(0, w->getNumChunks()).getMax(), 0.0f);
    delete w;
}

#pragma mark - Copying

- (void)testCopyConstructorDeepCopies {
    // Rule of three: a shallow copy of the chunks pointer would double-free.
    AudioWaveform *original = [self waveform];
    AudioWaveform *copy = new AudioWaveform(*original);

    AudioWaveformCacheChunk replaced;
    replaced.set(-99.0f, 99.0f);
    original->setChunkAtIndex(replaced, 0);

    XCTAssertEqual(original->getChunkAtIndex(0, 64).getMax(), 99.0f);
    XCTAssertEqual(copy->getChunkAtIndex(0, 64).getMax(), 0.0f,
                   @"the copy must not see writes to the original");
    delete original;
    delete copy;
}

#pragma mark - AudioWaveformCacheChunk

- (void)testAColumnWidensToTheExtremesOfItsChunks {
    AudioWaveformCacheChunk chunks[2];
    chunks[0].set(-1.0f, 2.0f);
    chunks[1].set(-3.0f, 1.0f);
    AudioWaveformCacheChunk widened = AudioWaveform(2, chunks).getChunkAtIndex(0, 1);
    XCTAssertEqual(widened.getMin(), -3.0f);
    XCTAssertEqual(widened.getMax(), 2.0f);

    chunks[0].set(-5.0f, 5.0f);
    chunks[1].set(-1.0f, 1.0f);
    AudioWaveformCacheChunk unmoved = AudioWaveform(2, chunks).getChunkAtIndex(0, 1);
    XCTAssertEqual(unmoved.getMin(), -5.0f);
    XCTAssertEqual(unmoved.getMax(), 5.0f);
}

- (void)testChunkFromMonoBufferTakesTheExtremes {
    // Chunks start at (0,0) and only ever widen, so a wholly positive buffer
    // keeps min 0 — the waveform is drawn symmetrically about the midline.
    const float samples[] = {0.25f, 0.75f, 0.5f};
    AudioWaveformCacheChunk c(samples, 3);
    XCTAssertEqual(c.getMin(), 0.0f);
    XCTAssertEqual(c.getMax(), 0.75f);
    XCTAssertEqualWithAccuracy(c.getMeanSquare(), (0.0625f + 0.5625f + 0.25f) / 3.0f, 1e-6);

    const float bipolar[] = {-0.6f, 0.2f};
    AudioWaveformCacheChunk d(bipolar, 2);
    XCTAssertEqual(d.getMin(), -0.6f);
    XCTAssertEqual(d.getMax(), 0.2f);
}

- (void)testNonFiniteSamplesAreClampedNotPropagated {
    // A corrupt decode must not reach the renderers: NaN would produce NaN
    // CGRects, and — since the decode still completes — get persisted under
    // the file hash, breaking that track until the entry ages out.
    const float withNaN[] = {0.5f, NAN, -0.25f};
    AudioWaveformCacheChunk c(withNaN, 3);
    XCTAssertTrue(std::isfinite(c.getMin()));
    XCTAssertTrue(std::isfinite(c.getMax()));
    XCTAssertTrue(std::isfinite(c.getMeanSquare()));

    const float withInf[] = {INFINITY, -INFINITY};
    AudioWaveformCacheChunk d(withInf, 2);
    XCTAssertTrue(std::isfinite(d.getMin()));
    XCTAssertTrue(std::isfinite(d.getMax()));
    XCTAssertTrue(std::isfinite(d.getMeanSquare()));
}

- (void)testChunkFromMonoBufferAccumulatesEnergyWeightedByFrames {
    const float first[] = {0.5f, -0.5f};       // meanSquare 0.25 over 2 frames
    AudioWaveformCacheChunk c(first, 2);
    XCTAssertEqualWithAccuracy(c.getMeanSquare(), 0.25f, 1e-6);

    const float second[] = {1.0f};             // meanSquare 1.0 over 1 frame
    c.mergeFromMonoBuffer(second, 1);
    XCTAssertEqualWithAccuracy(c.getMeanSquare(), (0.25f * 2 + 1.0f) / 3.0f, 1e-6);
}

- (void)testABarWeighsEachChunksEnergyByItsFrames {
    // Energy is a sum plus a frame count, not a stored mean, or a bar of
    // uneven chunks would count a short chunk as much as a long one.
    AudioWaveformCacheChunk chunks[3];
    chunks[0].set(0, 0, 4.0f, 2.0f);
    chunks[1].set(0, 0, 1.0f, 1.0f);
    chunks[2].set(0, 0, 10.0f, 5.0f);
    float meanSquare = 0;
    AudioWaveform(3, chunks).getBarMeanSquares(1, 0, &meanSquare, nullptr);
    XCTAssertEqualWithAccuracy(meanSquare, 15.0f / 8.0f, 1e-6);
}

- (void)testEmptyMonoBufferLeavesTheChunkUntouched {
    AudioWaveformCacheChunk c;
    c.set(-2.0f, 3.0f);
    c.mergeFromMonoBuffer(nullptr, 0);
    XCTAssertEqual(c.getMin(), -2.0f);
    XCTAssertEqual(c.getMax(), 3.0f);
    XCTAssertEqual(c.getMeanSquare(), 0.0f, @"no frames merged means no energy");
}

#pragma mark - AudioWaveformMonoMix

- (void)testMonoInputIsPassedThroughWithoutCopying {
    const float mono[] = {0.1f, 0.2f};
    float scratch[2] = {0};
    const float *out = AudioWaveformMonoMix(mono, scratch, 2, 1);
    XCTAssertEqual(out, (const float *)mono, @"mono must not pay for a copy");
}

- (void)testStereoIsAveragedIntoScratch {
    // Interleaved L0 R0 L1 R1.
    const float stereo[] = {1.0f, 3.0f, 2.0f, 4.0f};
    float scratch[2] = {0};
    const float *out = AudioWaveformMonoMix(stereo, scratch, 2, 2);
    XCTAssertEqual(out, (const float *)scratch);
    XCTAssertEqualWithAccuracy(out[0], 2.0f, 1e-6);
    XCTAssertEqualWithAccuracy(out[1], 3.0f, 1e-6);
}

- (void)testMultiChannelIsAveragedAcrossEveryChannel {
    // 3 channels, 2 frames: c0f0 c1f0 c2f0 c0f1 c1f1 c2f1.
    const float surround[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
    float scratch[2] = {0};
    const float *out = AudioWaveformMonoMix(surround, scratch, 2, 3);
    XCTAssertEqualWithAccuracy(out[0], 2.0f, 1e-6);
    XCTAssertEqualWithAccuracy(out[1], 5.0f, 1e-6);
}

@end
