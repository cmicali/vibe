//
//  PlaylistRowView.m
//  Vibe
//

#import "PlaylistRowView.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "NSView+DarkMode.h"

@implementation PlaylistRowView

// Read per draw; the record lookup is cheap.
- (NSColor *)selectedFillColor {
    return [AppSettings.sharedInstance.currentTheme
            displayColorForBase:kVibeThemeColorPlaylistSelectedRow dark:self.isDark];
}

- (NSColor *)playingFillColor {
    return [AppSettings.sharedInstance.currentTheme
            displayColorForBase:kVibeThemeColorPlaylistPlayingRow dark:self.isDark];
}

- (void)setPlayingRow:(BOOL)playingRow {
    if (_playingRow != playingRow) {
        _playingRow = playingRow;
        self.needsDisplay = YES;
    }
}

// No super: replaces the accent-blue fill rather than layering over it.
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [[self selectedFillColor] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
}

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    // A selected row already drew its wash; two read as a brighter row.
    if (_playingRow && !self.selected) {
        [[self playingFillColor] setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    }
}

@end
