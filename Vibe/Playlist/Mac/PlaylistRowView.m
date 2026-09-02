//
//  PlaylistRowView.m
//  Vibe
//

#import "PlaylistRowView.h"
#import "AppSettings.h"
#import "NSView+DarkMode.h"

@implementation PlaylistRowView

// The theme's overrides, alpha and all, over the neutral wash the display
// accessor defaults to. Read per draw: rows draw on state changes and
// scroll-in, and the record lookup is cheap.
- (NSColor *)selectedFillColor {
    return [AppSettings.sharedInstance.currentTheme
            displayPlaylistSelectedRowColorForDark:self.isDark];
}

- (NSColor *)playingFillColor {
    return [AppSettings.sharedInstance.currentTheme
            displayPlaylistPlayingRowColorForDark:self.isDark];
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
