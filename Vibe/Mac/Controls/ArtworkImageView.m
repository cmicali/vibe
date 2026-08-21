//
// Created by Christopher Micali on 12/31/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "ArtworkImageView.h"
#import "NSDraggingImageComponent+Util.h"
#import "MainWindowLayout.h"

// Movement (points) before a pressed mouse becomes a drag.
static const CGFloat kDragHysteresis = 3;

@implementation ArtworkImageView {
    // The exact URL instance startAccessingSecurityScopedResource was called
    // on. fileURL is a copy property and may be reassigned before the drag ends.
    NSURL *_securityScopedURL;
    // The mouseDown that may become a drag; nil once consumed or released.
    NSEvent *_pendingDragEvent;
}

- (BOOL)mouseDownCanMoveWindow {
    if (!self.fileURL) {
        return YES;
    }
    else {
        return NO;
    }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return self.fileURL != nil;
}

- (void)mouseDown:(NSEvent *)event {

    _pendingDragEvent = nil;

    if (!self.fileURL) {
        return;
    }

    CGPoint dragPosition = [self convertPoint:[event locationInWindow] fromView:nil];

    // Do not allow a drag near the buttons: the band where
    // MainPlayerContentView lays the transport SymbolButtons over the bottom
    // of the art.
    if (dragPosition.y < kArtworkTransportExclusionHeight) {
        return;
    }

    // Record only. mouseDragged: starts the session once the pointer moves;
    // starting here would flash a drag ghost on a plain click.
    _pendingDragEvent = event;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_pendingDragEvent) {
        return;
    }
    NSPoint start = [self convertPoint:_pendingDragEvent.locationInWindow fromView:nil];
    NSPoint current = [self convertPoint:event.locationInWindow fromView:nil];
    if (hypot(current.x - start.x, current.y - start.y) < kDragHysteresis) {
        return;
    }
    NSEvent *mouseDownEvent = _pendingDragEvent;
    _pendingDragEvent = nil;
    [self beginDragWithEvent:mouseDownEvent];
}

- (void)mouseUp:(NSEvent *)event {
    _pendingDragEvent = nil; // plain click — never became a drag
}

- (void)beginDragWithEvent:(NSEvent *)event {

    CGPoint dragPosition = [self convertPoint:[event locationInWindow] fromView:nil];

    NSURL *fileURL = self.fileURL;
    // Record for the drag-end stop only when the start took. The stop must
    // balance a successful start, since an unbalanced stop over-releases the
    // sandbox extension. A NO here, meaning the URL is not security-scoped,
    // still drags fine.
    if ([fileURL startAccessingSecurityScopedResource]) {
        _securityScopedURL = fileURL;
    }

    CGFloat imageSize = 48;
    CGRect imageRect = CGRectMake(0, 0, imageSize, imageSize);

    NSDraggingItem *draggingItem = [[NSDraggingItem alloc] initWithPasteboardWriter:fileURL];

    [draggingItem setImageComponentsProvider:^NSArray<NSDraggingImageComponent *> * {

        NSDraggingImageComponent *image = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentIconKey];
        image.frame = imageRect;
        image.contents = self.image;

        // Filename label; positions itself below the icon in the item's space.
        NSDraggingImageComponent *label = [NSDraggingImageComponent labelWithFile:self.fileURL imageRect:imageRect];

        return @[image, label];
    }];

    // Icon-sized, centered on the grab point.
    draggingItem.draggingFrame = CGRectMake(dragPosition.x - imageSize / 2,
                                            dragPosition.y - imageSize / 2,
                                            imageSize, imageSize);

    [self beginDraggingSessionWithItems:@[draggingItem]
                                  event:event
                                 source:self];

    // Note that the security-scoped access is deliberately *not* stopped here.
    // The drag is async, and stopping now would revoke the URL before the
    // receiving app had finished reading it. Access is released in
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
