//
//  PlaylistRowView.m
//  Vibe
//

#import "PlaylistRowView.h"
#import "NSView+DarkMode.h"

// White (dark mode) / black (light mode) at low opacity: reads as a quiet
// lift over the playlist frost in both appearances. Key-state independent,
// like the rest of the window chrome.
static const CGFloat kRowFillAlpha = 0.09;

@implementation PlaylistRowView

- (NSColor *)neutralFillColor {
    return [(self.isDark ? NSColor.whiteColor : NSColor.blackColor)
            colorWithAlphaComponent:kRowFillAlpha];
}

- (void)setPlayingRow:(BOOL)playingRow {
    if (_playingRow != playingRow) {
        _playingRow = playingRow;
        self.needsDisplay = YES;
    }
}

// No super call: this replaces the system selection fill (accent blue)
// outright rather than layering over it.
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [[self neutralFillColor] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
}

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    // Selected already draws the same wash via drawSelectionInRect: — don't
    // double up (two 9% passes read as a brighter row).
    if (_playingRow && !self.selected) {
        [[self neutralFillColor] setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    }
}

@end
