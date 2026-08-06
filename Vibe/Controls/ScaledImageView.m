//
// Created by Christopher Micali on 12/19/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "ScaledImageView.h"


@implementation ScaledImageView {
    // Dedupes a repeat setImage: with the same source. The visible image is a
    // scale-to-fill wrapper, so super's own dedupe never fires. A strong
    // reference is free, because the wrapper's drawing handler retains the
    // source anyway.
    NSImage *_currentImage;
}

- (id)init {
    self = [super init];
    if (self) {
        [super setImageScaling:NSImageScaleAxesIndependently];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        [super setImageScaling:NSImageScaleAxesIndependently];
    }
    return self;
}

- (id)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [super setImageScaling:NSImageScaleAxesIndependently];
    }
    return self;
}

- (void)setImageScaling:(NSImageScaling)newScaling
{
    // Ignore the requested scaling: the scale-to-fill wrapper works only with
    // NSImageScaleAxesIndependently.
    [super setImageScaling:NSImageScaleAxesIndependently];
}

- (void)setImage:(NSImage *)image {
    if (image == nil) {
        _currentImage = nil;
        [super setImage:image];
        return;
    }
    if (_currentImage == image) {
        return;
    }
    __weak ScaledImageView *weakSelf = self;
    NSImage *scaleToFillImage = [NSImage imageWithSize:self.bounds.size
                                               flipped:NO
                                        drawingHandler:^BOOL(NSRect dstRect) {

                                            NSSize imageSize = [image size];
                                            NSSize imageViewSize = weakSelf.bounds.size; // Yes, do not use dstRect.

                                            NSSize newImageSize = imageSize;

                                            CGFloat imageAspectRatio = imageSize.height/imageSize.width;
                                            CGFloat imageViewAspectRatio = imageViewSize.height/imageViewSize.width;

                                            if (imageAspectRatio < imageViewAspectRatio) {
                                                // Image is more horizontal than the view. Image left and right borders need to be cropped.
                                                newImageSize.width = imageSize.height / imageViewAspectRatio;
                                            }
                                            else {
                                                // Image is more vertical than the view. Image top and bottom borders need to be cropped.
                                                newImageSize.height = imageSize.width * imageViewAspectRatio;
                                            }

                                            CGFloat xpos = imageSize.width/2.0 - newImageSize.width/2.0;
                                            CGFloat ypos = imageSize.height/2.0 - newImageSize.height/2.0;
                                            NSRect srcRect = NSMakeRect(xpos, ypos, newImageSize.width, newImageSize.height);

                                            [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];

                                            [image drawInRect:dstRect // Interestingly, here needs to be dstRect and not self.bounds
                                                     fromRect:srcRect
                                                    operation:NSCompositingOperationCopy
                                                     fraction:1.0
                                               respectFlipped:YES
                                                        hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];

                                            [weakSelf drawImageOverlayInRect:dstRect];

                                            return YES;
                                        }];
    [scaleToFillImage setCacheMode:NSImageCacheBySize];
    [super setImage:scaleToFillImage];
    _currentImage = image;
}

- (void)drawImageOverlayInRect:(NSRect)rect {

}

@end
