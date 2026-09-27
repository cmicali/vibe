//
//  ScaledImageView.m
//  Vibe
//

#import "ScaledImageView.h"


@implementation ScaledImageView {
    // Dedupes setImage: by source: the visible image is a wrapper, so super's
    // dedupe never fires. Strong is free; the wrapper retains the source.
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
    // The scale-to-fill wrapper needs NSImageScaleAxesIndependently.
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
                                            NSSize imageViewSize = weakSelf.bounds.size; // deliberately not dstRect

                                            NSSize newImageSize = imageSize;

                                            CGFloat imageAspectRatio = imageSize.height/imageSize.width;
                                            CGFloat imageViewAspectRatio = imageViewSize.height/imageViewSize.width;

                                            if (imageAspectRatio < imageViewAspectRatio) {
                                                // Wider than the view: crop left and right.
                                                newImageSize.width = imageSize.height / imageViewAspectRatio;
                                            }
                                            else {
                                                // Taller than the view: crop top and bottom.
                                                newImageSize.height = imageSize.width * imageViewAspectRatio;
                                            }

                                            CGFloat xpos = imageSize.width/2.0 - newImageSize.width/2.0;
                                            CGFloat ypos = imageSize.height/2.0 - newImageSize.height/2.0;
                                            NSRect srcRect = NSMakeRect(xpos, ypos, newImageSize.width, newImageSize.height);

                                            [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];

                                            [image drawInRect:dstRect // must be dstRect here, not self.bounds
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
