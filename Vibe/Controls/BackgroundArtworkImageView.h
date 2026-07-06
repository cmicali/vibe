//
// Created by Christopher Micali on 12/31/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface BackgroundArtworkImageView : NSImageView

// Renders a pre-blurred/dimmed copy of the artwork on a background queue and
// sets it as the view's image. Replaces the old live CIGaussianBlur filter.
- (void)setArtworkImage:(NSImage *)image;

@end
