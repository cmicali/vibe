//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "DetailedAudioWaveformRenderer.h"

@implementation AudioWaveformRenderer {
    NSMutableArray<CALayer*> *_otherLayers;
}

- (instancetype)initWithLayer:(CALayer*)layer bounds:(CGRect)bounds {
    self = [super init];
    if (self) {
        self.parentLayer = layer;
        _otherLayers = [NSMutableArray new];
    }
    return self;
}

- (void) dealloc {
    for (CALayer *layer in _layers) {
        [layer removeFromSuperlayer];
    }
    for (CALayer *layer in _otherLayers) {
        [layer removeFromSuperlayer];
    }
}

+ (NSString *)displayName {
    return nil;
}

- (void)addOtherLayer:(CALayer*)layer {
    [self.parentLayer addSublayer:layer];
    [_otherLayers addObject:layer];
}

- (void)addLayers:(NSUInteger)numLayers backgroundColor:(CGColorRef)color {
    [self addLayers:numLayers forClass:CALayer.class backgroundColor:color];
}

- (void)addLayers:(NSUInteger)numLayers forClass:(Class)clazz backgroundColor:(CGColorRef)color {
    NSMutableArray *layers = [NSMutableArray new];
    for (int i = 0; i < numLayers; ++i) {
        CALayer *layer = (CALayer *)[[clazz alloc] init];
        layer.backgroundColor = color;
        [layers addObject:layer];
        [self.parentLayer addSublayer:layer];
    }
    self.layers = layers;
}

- (CAGradientLayer*) createGradientLayer:(NSArray<NSColor*>*)colors {
    return [self createGradientLayer:colors filter:nil];
}

- (CAGradientLayer*) createGradientLayer:(NSArray<NSColor*>*)colors filter:(NSString * __nullable)filterName {
    CAGradientLayer *layer = [[CAGradientLayer alloc] init];
    NSMutableArray *cgColors = [[NSMutableArray alloc] initWithCapacity:colors.count];
    for (NSColor *color in colors) {
        [cgColors addObject:(id)color.CGColor];
    }
    layer.colors = cgColors;
    if (filterName.length) {
        CIFilter *filter = [CIFilter filterWithName:filterName];
        [filter setDefaults];
        layer.compositingFilter = filter;
    }
    return layer;
}

- (void)willUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {
    self.bottomY = bounds.size.height/2 - (bounds.size.height/2 * .5);
    self.topY = bounds.size.height/2 + (bounds.size.height/2 * .5);
}

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {

}

- (void)didUpdateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform *__nullable)waveform {

}

@end
