//
// Created by Christopher Micali on 12/31/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "BackgroundArtworkImageView.h"

@implementation BackgroundArtworkImageView

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
