//
// Created by Christopher Micali on 12/31/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "BackgroundArtworkImageView.h"
#import <CoreImage/CoreImage.h>

#define BACKGROUND_ART_TARGET_SIZE      150.0
#define BACKGROUND_ART_BLUR_RADIUS      15.0
// Dark base the art is overlay-blended onto, standing in for the behind-window
// material the old CIOverlayBlendMode compositing filter blended against.
#define BACKGROUND_ART_BASE_GRAY        0.12

@implementation BackgroundArtworkImageView {
    NSUInteger _artworkGeneration;
    NSImage *_sourceImage;
}

+ (CIContext *)sharedBlurContext {
    static CIContext *context = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        context = [CIContext contextWithOptions:nil];
    });
    return context;
}

- (void)setArtworkImage:(NSImage *)image {
    _sourceImage = image;
    [self renderArtwork];
}

- (void)renderArtwork {
    NSUInteger generation = ++_artworkGeneration;
    NSImage *image = _sourceImage;
    if (!image) {
        self.image = nil;
        return;
    }
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) {
        self.image = image;
        return;
    }
    CIImage *input = [CIImage imageWithCGImage:cgImage];
    NSSize viewSize = self.bounds.size;
    if (viewSize.width < 1 || viewSize.height < 1) {
        viewSize = image.size;
    }
    __weak BackgroundArtworkImageView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSImage *blurred = [BackgroundArtworkImageView blurredImageFromCIImage:input viewSize:viewSize];
        dispatch_async(dispatch_get_main_queue(), ^{
            BackgroundArtworkImageView *strongSelf = weakSelf;
            if (strongSelf && generation == strongSelf->_artworkGeneration) {
                strongSelf.image = blurred ?: image;
            }
        });
    });
}

- (void)setFrameSize:(NSSize)newSize {
    CGFloat oldAspect = self.bounds.size.height > 0 ? self.bounds.size.width / self.bounds.size.height : 0;
    [super setFrameSize:newSize];
    CGFloat newAspect = newSize.height > 0 ? newSize.width / newSize.height : 0;
    // The blurred bitmap is baked at the view's aspect ratio; re-render when it changes.
    if (_sourceImage && newAspect > 0 && fabs(newAspect - oldAspect) > 0.01) {
        [self renderArtwork];
    }
}

+ (NSImage *)blurredImageFromCIImage:(CIImage *)input viewSize:(NSSize)viewSize {
    CGRect extent = input.extent;
    if (CGRectIsEmpty(extent) || CGRectIsInfinite(extent)) {
        return nil;
    }
    // Center-crop to the view's aspect ratio so the result fills the view edge to edge.
    CGFloat targetAspect = viewSize.width / viewSize.height;
    CGRect crop = extent;
    if (extent.size.width / extent.size.height > targetAspect) {
        crop.size.width = extent.size.height * targetAspect;
        crop.origin.x += (extent.size.width - crop.size.width) / 2.0;
    } else {
        crop.size.height = extent.size.width / targetAspect;
        crop.origin.y += (extent.size.height - crop.size.height) / 2.0;
    }
    CIImage *cropped = [input imageByCroppingToRect:crop];
    CGFloat maxDimension = MAX(crop.size.width, crop.size.height);
    CGFloat scale = MIN(1.0, BACKGROUND_ART_TARGET_SIZE / maxDimension);
    CIImage *small = [cropped imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect smallExtent = small.extent;
    // Clamp so the blur doesn't fade to transparent at the edges, then crop back.
    CIImage *blurred = [[small imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:BACKGROUND_ART_BLUR_RADIUS];
    blurred = [blurred imageByCroppingToRect:smallExtent];
    // Overlay-blend onto a dark base, matching the old compositing filter's look
    // (overlay over a dark backdrop ≈ 2 × base × art: dark, tinted by the art).
    CIImage *base = [[CIImage imageWithColor:[CIColor colorWithRed:BACKGROUND_ART_BASE_GRAY
                                                             green:BACKGROUND_ART_BASE_GRAY
                                                              blue:BACKGROUND_ART_BASE_GRAY]] imageByCroppingToRect:smallExtent];
    CIFilter *overlay = [CIFilter filterWithName:@"CIOverlayBlendMode"];
    [overlay setValue:blurred forKey:kCIInputImageKey];
    [overlay setValue:base forKey:kCIInputBackgroundImageKey];
    CIImage *result = [overlay.outputImage imageByCroppingToRect:smallExtent];
    if (!result) {
        return nil;
    }
    CGImageRef outputImage = [[self sharedBlurContext] createCGImage:result fromRect:smallExtent];
    if (!outputImage) {
        return nil;
    }
    // Bake the bitmap at the view's aspect ratio and point size so the cell's
    // proportional scaling fills the view exactly.
    NSImage *output = [[NSImage alloc] initWithCGImage:outputImage size:viewSize];
    CGImageRelease(outputImage);
    return output;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {
    [self unregisterDraggedTypes];
}

- (BOOL)mouseDownCanMoveWindow {
    return YES;
}

- (NSView *)hitTest:(NSPoint)point {
    // Return nil so this view doesn’t block drag events or mouse events
    return nil;
}

@end
