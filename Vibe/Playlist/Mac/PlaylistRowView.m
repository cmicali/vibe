//
//  PlaylistRowView.m
//  Vibe
//

#import "PlaylistRowView.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "NSView+DarkMode.h"
#import "PlaylistTableView.h"
#import "PlaylistTextCell.h"

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
        [self applyTextColor];
    }
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self applyTextColor];
}

// A cell arrives with whatever its last row pushed, so a reused one must be
// told this row's color.
- (void)didAddSubview:(NSView *)subview {
    [super didAddSubview:subview];
    [self applyTextColor];
}

- (void)applyTextColor {
    NSColor *color = [PlaylistTableView textColorForRowSelected:self.selected playing:_playingRow];
    for (NSView *subview in self.subviews) {
        if (![subview isKindOfClass:NSTableCellView.class]) {
            continue;
        }
        NSCell *cell = ((NSTableCellView *)subview).textField.cell;
        if ([cell isKindOfClass:PlaylistTextCell.class]) {
            ((PlaylistTextCell *)cell).rowTextColor = color;
        }
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
