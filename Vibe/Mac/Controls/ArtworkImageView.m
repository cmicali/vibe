//
//  ArtworkImageView.m
//  Vibe
//

#import "ArtworkImageView.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
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

    // Not in the band under the transport buttons.
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
    // Read once here: the mode must not change under an in-flight drag.
    NSString *action = AppSettings.sharedInstance.artworkDragAction;

    // Only the file payload is read after the drop, so only it holds the
    // security scope open. The path mode keeps the filename label: a full path
    // draws a screen-wide ghost.
    id<NSPasteboardWriting> writer = fileURL;
    NSString *labelText = fileURL.path.lastPathComponent;
    BOOL wantsSecurityScope = YES;
    if ([action isEqualToString:SETTINGS_VALUE_ARTWORK_DRAG_COPY_PATH]) {
        writer = fileURL.path;
        wantsSecurityScope = NO;
    }
    else if ([action isEqualToString:SETTINGS_VALUE_ARTWORK_DRAG_COPY_ARTIST_TITLE]) {
        if (self.trackDisplayName.length == 0) {
            return;
        }
        writer = self.trackDisplayName;
        labelText = self.trackDisplayName;
        wantsSecurityScope = NO;
    }
    // Close or a playback failure can clear the file after mouseDown, and a
    // nil payload or label raises inside AppKit.
    if (!fileURL || !writer || labelText.length == 0) {
        return;
    }

    // Recorded only when the start took: an unbalanced stop over-releases the
    // sandbox extension. NO (not security-scoped) still drags.
    if (wantsSecurityScope && [fileURL startAccessingSecurityScopedResource]) {
        _securityScopedURL = fileURL;
    }

    CGFloat imageSize = 48;
    CGRect imageRect = CGRectMake(0, 0, imageSize, imageSize);

    NSDraggingItem *draggingItem = [[NSDraggingItem alloc] initWithPasteboardWriter:writer];

    [draggingItem setImageComponentsProvider:^NSArray<NSDraggingImageComponent *> * {

        NSDraggingImageComponent *image = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentIconKey];
        image.frame = imageRect;
        image.contents = self.image;

        NSDraggingImageComponent *label = [NSDraggingImageComponent labelWithString:labelText imageRect:imageRect];

        return @[image, label];
    }];

    // Icon-sized, centered on the grab point.
    draggingItem.draggingFrame = CGRectMake(dragPosition.x - imageSize / 2,
                                            dragPosition.y - imageSize / 2,
                                            imageSize, imageSize);

    [self beginDraggingSessionWithItems:@[draggingItem]
                                  event:event
                                 source:self];

    // The scope stays open: the drag is async, and the receiver is still
    // reading. draggingSession:endedAtPoint:operation: releases it.
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
