//
//  VibeLinkLabel.m
//  Vibe
//

#import "VibeLinkLabel.h"

@implementation VibeLinkLabel

- (void)setLinkURL:(NSURL *)linkURL {
    _linkURL = [linkURL copy];
    // The ring comes from drawFocusRingMask, not the full-width frame.
    self.focusRingType = linkURL ? NSFocusRingTypeExterior : NSFocusRingTypeNone;
}

// One centered line, so two measurements place it without a layout manager.
- (NSRect)linkRect {
    NSAttributedString *text = self.attributedStringValue;
    if (!self.linkURL || self.linkRange.length == 0
            || NSMaxRange(self.linkRange) > text.length) {
        return NSZeroRect;
    }
    CGFloat total = ceil(text.size.width);
    CGFloat before = ceil([text attributedSubstringFromRange:
            NSMakeRange(0, self.linkRange.location)].size.width);
    CGFloat width = ceil([text attributedSubstringFromRange:self.linkRange].size.width);
    CGFloat x = round((NSWidth(self.bounds) - total) / 2.0) + before;
    return NSMakeRect(x, 0, width, NSHeight(self.bounds));
}

- (void)activateLink {
    if (self.linkURL) {
        [NSWorkspace.sharedWorkspace openURL:self.linkURL];
    }
}

#pragma mark - Pointer

- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return NSMouseInRect(local, self.linkRect, self.isFlipped) ? self : nil;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    NSRect rect = self.linkRect;
    if (!NSIsEmptyRect(rect)) {
        [self addCursorRect:rect cursor:NSCursor.pointingHandCursor];
    }
}

// Claimed, so the matching mouseUp routes here; the link opens on the up.
- (void)mouseDown:(NSEvent *)event {
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSMouseInRect(local, self.linkRect, self.isFlipped)) {
        [self activateLink];
    }
}

#pragma mark - Keyboard

- (BOOL)acceptsFirstResponder {
    return self.linkURL != nil;
}

- (BOOL)canBecomeKeyView {
    return self.linkURL != nil && !self.isHiddenOrHasHiddenAncestor;
}

- (BOOL)becomeFirstResponder {
    [self noteFocusRingMaskChanged];
    return [super becomeFirstResponder];
}

- (BOOL)resignFirstResponder {
    [self noteFocusRingMaskChanged];
    return [super resignFirstResponder];
}

- (void)drawFocusRingMask {
    NSRect rect = self.linkRect;
    if (!NSIsEmptyRect(rect)) {
        NSRectFill(rect);
    }
}

- (NSRect)focusRingMaskBounds {
    return self.linkRect;
}

- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers;
    unichar key = characters.length ? [characters characterAtIndex:0] : 0;
    if (self.linkURL && (key == NSCarriageReturnCharacter || key == NSEnterCharacter || key == ' ')) {
        [self activateLink];
        return;
    }
    [super keyDown:event];
}

#pragma mark - Accessibility

// Named by the whole visible line, so nothing the plain label said is lost;
// the frame covers only the underlined name.
- (BOOL)isAccessibilityElement {
    return self.linkURL != nil ? YES : [super isAccessibilityElement];
}

- (NSAccessibilityRole)accessibilityRole {
    return self.linkURL != nil ? NSAccessibilityLinkRole : [super accessibilityRole];
}

- (NSString *)accessibilityLabel {
    return self.linkURL != nil ? self.stringValue : [super accessibilityLabel];
}

- (NSURL *)accessibilityURL {
    return self.linkURL;
}

- (NSRect)accessibilityFrame {
    NSRect rect = self.linkRect;
    if (NSIsEmptyRect(rect) || !self.window) {
        return [super accessibilityFrame];
    }
    return [self.window convertRectToScreen:[self convertRect:rect toView:nil]];
}

- (BOOL)accessibilityPerformPress {
    if (!self.linkURL) {
        return NO;
    }
    [self activateLink];
    return YES;
}

@end
