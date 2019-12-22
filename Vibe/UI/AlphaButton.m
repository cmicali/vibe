//
// Created by Christopher Micali on 12/19/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AlphaButton.h"

#define ALPHA_ENABLED           0.7
#define ALPHA_ENABLED_HOVER     0.9
#define ALPHA_ENABLED_PRESSED   0.3
#define ALPHA_DISABLED          0.3

@implementation AlphaButton {
    BOOL _mouseInside;
    BOOL _mouseDown;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setup];
    }

    return self;
}

- (void)setup {
    self.alphaValue = ALPHA_ENABLED;
    NSTrackingArea* trackingArea = [[NSTrackingArea alloc]
            initWithRect:[self bounds]
                 options:NSTrackingMouseEnteredAndExited |
                         NSTrackingEnabledDuringMouseDrag |
                         NSTrackingActiveAlways
                   owner:self userInfo:nil];
    [self addTrackingArea:trackingArea];
    [self updateAlpha];
}

- (void)updateAlpha {
    LogDebug(@"update: down: %@ inside: %@", _mouseDown ? @"YES" : @"NO", _mouseInside ? @"YES" : @"NO");
    if (self.enabled) {
        if (_mouseDown) {
            if (_mouseInside) {
                self.alphaValue = ALPHA_ENABLED_PRESSED;
            }
            else {
                self.alphaValue = ALPHA_ENABLED;
            }
        }
        else {
            if (_mouseInside) {
                self.alphaValue = ALPHA_ENABLED_HOVER;
            }
            else {
                self.alphaValue = ALPHA_ENABLED;
            }
        }
    }
    else {
        self.alphaValue = ALPHA_DISABLED;
    }
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    _mouseInside = YES;
    [self updateAlpha];
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    _mouseInside = NO;
    [self updateAlpha];
}

- (void)mouseDown:(NSEvent *)event {
    [super mouseDown:event];
    _mouseDown = YES;
    [self updateAlpha];
}

- (void)mouseUp:(NSEvent *)event {
    [super mouseUp:event];
    _mouseDown = NO;
    [self updateAlpha];
}

- (void)mouseDragged:(NSEvent *)event {
    [super mouseDragged:event];
    _mouseInside = CGRectContainsPoint(self.frame, event.locationInWindow);
    [self updateAlpha];
}

- (void)setEnabled:(BOOL)enabled {
    super.enabled = enabled;
    [self updateAlpha];
}

@end