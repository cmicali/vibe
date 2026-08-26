//
//  PlaylistRowView.m
//  Vibe
//

#import "PlaylistRowView.h"
#import "AppSettings.h"
#import "NSView+DarkMode.h"

// White in dark mode and black in light, at low opacity, which reads as a
// quiet lift over the playlist frost in both appearances. It is independent of
// key state, like the rest of the window chrome.
static const CGFloat kRowFillAlpha = 0.09;

@implementation PlaylistRowView

- (NSColor *)neutralFillColor {
    return [(self.isDark ? NSColor.whiteColor : NSColor.blackColor)
            colorWithAlphaComponent:kRowFillAlpha];
}

// The theme's overrides, alpha and all, over the neutral wash. Read per draw:
// rows draw on state changes and scroll-in, and the record lookup is cheap.
- (NSColor *)selectedFillColor {
    return [AppSettings.sharedInstance.currentTheme
                    playlistSelectedRowColorForDark:self.isDark]
            ?: [self neutralFillColor];
}

- (NSColor *)playingFillColor {
    return [AppSettings.sharedInstance.currentTheme
                    playlistPlayingRowColorForDark:self.isDark]
            ?: [self neutralFillColor];
}

- (void)setPlayingRow:(BOOL)playingRow {
    if (_playingRow != playingRow) {
        _playingRow = playingRow;
        self.needsDisplay = YES;
    }
}

// There is no super call: this replaces the system's accent-blue selection
// fill outright rather than layering over it.
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [[self selectedFillColor] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
}

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    // A selected row already draws the same wash through drawSelectionInRect:,
    // so do not double up: two 9% passes read as a brighter row.
    if (_playingRow && !self.selected) {
        [[self playingFillColor] setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    }
}

@end
