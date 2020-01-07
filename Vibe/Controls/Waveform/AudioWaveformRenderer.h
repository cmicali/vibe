//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>
#import "AudioWaveform.h"

@class AudioWaveform;

NS_ASSUME_NONNULL_BEGIN

@interface AudioWaveformRenderer : NSObject

@property (assign) CGFloat topY;
@property (assign) CGFloat bottomY;
@property (assign) CGFloat progress;

@property (strong) CALayer* parentLayer;
@property (strong) NSArray<CALayer*>* layers;

+ (NSString *)displayName;

- (instancetype)initWithLayer:(CALayer*)layer bounds:(CGRect)bounds;

- (void)addLayers:(NSUInteger)numLayers backgroundColor:(CGColorRef)color;
- (void)addLayers:(NSUInteger)numLayers forClass:(Class)clazz backgroundColor:(CGColorRef)color;
- (void)addOtherLayer:(CALayer *)layer;

- (CAGradientLayer *)createGradientLayer:(NSArray<NSColor *> *)colors;
- (CAGradientLayer *)createGradientLayer:(NSArray<NSColor *> *)colors filter:(NSString * __nullable)filterName;

- (void)setLayerFrame:(CGRect)frame atIndex:(NSUInteger)index;

- (void)setLayerColor:(NSColor *)color atIndex:(NSUInteger)index;

- (void)willUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform * __nullable)waveform;
- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;
- (void)didUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform * __nullable)waveform;
- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;

@end

NS_ASSUME_NONNULL_END
