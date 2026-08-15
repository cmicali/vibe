//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "BasicAudioWaveformRenderer.h"
#import "VibeStrings.h"

#define kBasicBarCount 128
#define kBasicBarWidth 3

@implementation BasicAudioWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"basic";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_BASIC;
}

- (NSUInteger)numBars {
    return kBasicBarCount;
}

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count {
    return kBasicBarWidth;
}

- (CGFloat)barXForIndex:(NSUInteger)index width:(CGFloat)width barCount:(NSUInteger)count barWidth:(CGFloat)barWidth {
    // Fixed-width bars on a width-over-count pitch, so a gap opens between
    // them, unlike Detailed, whose bars tile the width edge to edge.
    return width * (CGFloat)index / (CGFloat)count;
}

- (void)configureGradient:(CAGradientLayer *)gradient {
    // Keep the default vertical axis over the full view. Basic's four-stop
    // colors below are designed against it, not against Detailed's
    // band-pinned fade.
}

- (NSArray<NSColor *> *)playedGradientColors:(NSColor *)baseColor isDark:(BOOL)isDark {
    NSArray *colors = @[
            [baseColor colorWithAlphaComponent:0.1],
            [baseColor colorWithAlphaComponent:0.65],
            [baseColor colorWithAlphaComponent:1.0],
            [baseColor colorWithAlphaComponent:1.0],
    ];
    return isDark ? colors : [[colors reverseObjectEnumerator] allObjects];
}

- (NSArray<NSColor *> *)unplayedGradientColors:(NSColor *)baseColor isDark:(BOOL)isDark {
    NSArray *colors = @[
            [baseColor colorWithAlphaComponent:0.05],
            [baseColor colorWithAlphaComponent:0.325],
            [baseColor colorWithAlphaComponent:0.5],
            [baseColor colorWithAlphaComponent:0.5],
    ];
    return isDark ? colors : [[colors reverseObjectEnumerator] allObjects];
}

@end
