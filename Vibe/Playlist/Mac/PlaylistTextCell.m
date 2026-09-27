//
//  PlaylistTextCell.m
//  Vibe
//

#import "PlaylistTextCell.h"


@implementation PlaylistTextCell {

}

- (instancetype)initTextCell:(NSString *)string {
    self = [super initTextCell:string];
    if (self) {
        [self setup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setup];
    }
    return self;
}

// Single-line mode keeps a long title to one line; it does not center it —
// drawingRectForBounds: does.
//
// TRAP: truncation here is not enough. An attributed string's paragraph style
// beats the cell's lineBreakMode and defaults to wrapping, so
// PlaylistTableView's attributes must truncate too.
- (void)setup {
    self.editable = NO;
    self.usesSingleLineMode = YES;
    self.lineBreakMode = NSLineBreakByTruncatingTail;
}

// Unconditional because the cell is never editable: a shrunken drawing rect
// would otherwise misplace the field editor.
- (NSRect)drawingRectForBounds:(NSRect)bounds {
    NSRect rect = [super drawingRectForBounds:bounds];
    CGFloat slack = NSHeight(rect) - [self cellSizeForBounds:bounds].height;
    if (slack > 0) {
        rect.origin.y += slack / 2;
        rect.size.height -= slack;
    }
    return rect;
}

@end