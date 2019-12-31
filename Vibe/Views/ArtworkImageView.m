//
// Created by Christopher Micali on 12/31/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "ArtworkImageView.h"
#import "NSDraggingImageComponent+Util.h"


@implementation ArtworkImageView

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

- (void)mouseDown:(NSEvent *)event {

    if (!self.fileURL) {
        return;
    }

    [self.fileURL startAccessingSecurityScopedResource];

    CGFloat imageSize = 48;

    NSDraggingItem *draggingItem = [[NSDraggingItem alloc] initWithPasteboardWriter:self.fileURL];


    [draggingItem setImageComponentsProvider:^NSArray<NSDraggingImageComponent *> * {

        CGRect imageRect = CGRectMake(0, 0, imageSize, imageSize);
        NSDraggingImageComponent *image = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentIconKey];
        image.frame = imageRect;
        image.contents = self.image;

        NSDraggingImageComponent *label = [NSDraggingImageComponent labelWithFile:self.fileURL imageRect:imageRect];

        return @[image, label];
    }];

    CGPoint dragPosition = [self convertPoint:[event locationInWindow] fromView:nil];
    dragPosition.x -= imageSize/2;
    dragPosition.y -= imageSize/2;
    draggingItem.draggingFrame = CGRectMake(dragPosition.x, dragPosition.y, imageSize, imageSize * 4);

    [self beginDraggingSessionWithItems:@[draggingItem]
                                  event:event
                                 source:self];

    [self.fileURL stopAccessingSecurityScopedResource];

}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    if (context == NSDraggingContextOutsideApplication) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}


@end
