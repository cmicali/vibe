//
//  VibeLinkLabel.m
//  Vibe
//

#import "VibeLinkLabel.h"

@implementation VibeLinkLabel

- (void)setLinkURL:(NSURL *)linkURL {
    _linkURL = [linkURL copy];
    // Only a label carrying a link draws a ring, and AppKit draws it from
    // drawFocusRingMask below rather than around the full-width frame.
    self.focusRingType = linkURL ? NSFocusRingTypeExterior : NSFocusRingTypeNone;
}

// The text is a single centered line, so measuring the whole string and the
// part before the link places it without a layout manager.
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

// Claim the down rather than forwarding to super — only a claimed down routes
// the matching mouseUp here — and open on the up, with the cursor still over
// the link, like any standard link.
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

// The ring follows the glyphs, not the full-width frame the label occupies.
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

// The whole visible line is the element's name, so nothing a reader could hear
// from the plain label is lost by its becoming a link; the actionable part of
// it is the underlined name, which is what the frame below covers.
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
