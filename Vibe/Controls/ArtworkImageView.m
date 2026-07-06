//
// Created by Christopher Micali on 12/31/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "ArtworkImageView.h"
#import "NSDraggingImageComponent+Util.h"


@implementation ArtworkImageView {
    // The exact URL instance startAccessingSecurityScopedResource was called
    // on; fileURL may be reassigned (it's a copy property) before drag end.
    NSURL *_securityScopedURL;
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
    if (!self.fileURL) {
        return YES;
    }
    else {
        return NO;
    }
}

- (void)mouseDown:(NSEvent *)event {

    if (!self.fileURL) {
        return;
    }

    CGPoint dragPosition = [self convertPoint:[event locationInWindow] fromView:nil];

    // Don't allow drag near buttons
    if (dragPosition.y < 42) {
        return;
    }

    NSURL *fileURL = self.fileURL;
    [fileURL startAccessingSecurityScopedResource];
    _securityScopedURL = fileURL;

    CGFloat imageSize = 48;

    NSDraggingItem *draggingItem = [[NSDraggingItem alloc] initWithPasteboardWriter:fileURL];


    [draggingItem setImageComponentsProvider:^NSArray<NSDraggingImageComponent *> * {

        CGRect imageRect = CGRectMake(0, 0, imageSize, imageSize);
        NSDraggingImageComponent *image = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentIconKey];
        image.frame = imageRect;
        image.contents = self.image;

        NSDraggingImageComponent *label = [NSDraggingImageComponent labelWithFile:self.fileURL imageRect:imageRect];

        return @[image, label];
    }];

    dragPosition.x -= imageSize/2;
    dragPosition.y -= imageSize/2;
    draggingItem.draggingFrame = CGRectMake(dragPosition.x, dragPosition.y, imageSize, imageSize * 4);

    [self beginDraggingSessionWithItems:@[draggingItem]
                                  event:event
                                 source:self];

    // Note: we do *not* stop the security-scoped access here. The drag is
    // async — stopping now would revoke the URL before the receiving app
    // has finished reading it. We release access in
    // draggingSession:endedAtPoint:operation: below.
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    if (context == NSDraggingContextOutsideApplication) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    [_securityScopedURL stopAccessingSecurityScopedResource];
    _securityScopedURL = nil;
}


@end
