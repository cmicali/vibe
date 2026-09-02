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

// Single-line mode collapses a wrapping title to one line, which is half of
// what this cell is for. A title long enough to wrap otherwise took two lines:
// the first rode high in the 28pt row and the second was clipped away, and the
// row's text then sat visibly above the duration beside it.
//
// It does NOT center that line, though — a single-line cell is still laid out
// from the top of its frame, about 6pt high in a 28pt row. The centering is
// -drawingRectForBounds: below.
//
// TRAP: the truncation is set here as well as in the attributes the table
// builds in PlaylistTableView, because an attributed string's own paragraph
// style beats the cell's line break mode, and its default is to wrap.
- (void)setup {
    self.editable = NO;
    self.usesSingleLineMode = YES;
    self.lineBreakMode = NSLineBreakByTruncatingTail;
}

// Center the single line of text in the row: measure it at its natural height
// and give away half the slack from the top.
//
// This needs none of the field-editor dance a centered *editable* text cell
// requires. The usual version of this has to intercept -selectWithFrame: and
// -editWithFrame: and suppress the centering while editing, because a shrunken
// drawing rect misplaces the field editor. This cell sets editable = NO above,
// so no field editor is ever installed and the centering can be unconditional.
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