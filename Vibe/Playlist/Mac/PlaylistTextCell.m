//
//  PlaylistTextCell.m
//  Vibe
//

#import "PlaylistTextCell.h"


NSAttributedStringKey const PlaylistColumnAttributeName = @"VibePlaylistColumn";

@implementation PlaylistTextCell {
    // As the controller set it, before the row colors.
    NSAttributedString *_contentString;
    NSDictionary<NSString *, NSColor *> *_rowColors;
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

- (void)setAttributedStringValue:(NSAttributedString *)value {
    _contentString = [value copy];
    [super setAttributedStringValue:[self drawnString]];
}

- (void)setRowColors:(NSDictionary<NSString *, NSColor *> *)colors {
    if (colors == _rowColors) {
        return;
    }
    _rowColors = colors;
    if (_contentString) {
        [super setAttributedStringValue:[self drawnString]];
    }
}

- (NSAttributedString *)drawnString {
    if (!_rowColors || _contentString.length == 0) {
        return _contentString;
    }
    NSMutableAttributedString *drawn = [_contentString mutableCopy];
    [_contentString enumerateAttribute:PlaylistColumnAttributeName
                               inRange:NSMakeRange(0, drawn.length)
                               options:0
                            usingBlock:^(NSString *column, NSRange range, BOOL *stop) {
        NSColor *color = column ? self->_rowColors[column] : nil;
        if (color) {
            [drawn addAttribute:NSForegroundColorAttributeName value:color range:range];
        }
    }];
    return drawn;
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