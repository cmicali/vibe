//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>
#import "AudioWaveform.h"

NS_ASSUME_NONNULL_BEGIN

#define setLayerFrame(frame, index) \
{ \
    self.layers[index].frame = frame; \
    CGFloat bottom = frame.origin.y; \
    CGFloat top = bottom + frame.size.height; \
    if (top > self.topY) { \
        self.topY = top; \
    } \
    if (bottom < self.bottomY) { \
        self.bottomY = bottom; \
    } \
}

#define setLayerColor(color, index) \
{ \
    CGColorRef c = (color).CGColor; \
    CALayer *layer = self.layers[index]; \
    if (!CGColorEqualToColor(layer.backgroundColor, c)) { \
        layer.backgroundColor = c; \
    } \
}

@interface AudioWaveformRenderer : NSObject

@property (assign) CGFloat topY;
@property (assign) CGFloat bottomY;
@property (assign) CGFloat progress;
@property (assign) BOOL isDark;

@property (strong) CALayer* parentLayer;
@property (strong) NSArray<CALayer*>* layers;

+ (NSString *)displayName;

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark;

- (void)updateColors:(BOOL)isDark;
- (void)addLayers:(NSUInteger)numLayers backgroundColor:(CGColorRef)color;
- (void)addLayers:(NSUInteger)numLayers forClass:(Class)clazz backgroundColor:(CGColorRef)color;
- (void)addOtherLayer:(CALayer *)layer;

- (CAGradientLayer*) createGradientLayer;
- (CAGradientLayer*) createGradientLayer:(NSString * __nullable)filterName;
- (void) setGradientLayerColors:(CAGradientLayer*)layer colors:(NSArray<NSColor*>*)colors;

- (void)willUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform * __nullable)waveform;
- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;
- (void)didUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform * __nullable)waveform;
- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;

@end

NS_ASSUME_NONNULL_END
