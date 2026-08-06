//
// Created by Christopher Micali on 12/19/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
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

// Single-line mode is what makes this cell live up to its name. A plain
// NSTextFieldCell lays its text out from the top of the cell, so a row's text
// only looked centered while every column happened to be one line at the same
// font size. A title long enough to wrap took two lines: the first rode high in
// the 28pt row and the second was clipped away, and the row's text then sat
// visibly above the duration beside it. Single-line mode collapses the layout
// to one line and centers it vertically, so the cells line up whatever the
// string's length.
//
// The truncation is set here as well as in the attributes the table builds in
// PlaylistTableView, because an attributed string's own paragraph style beats
// the cell's line break mode, and its default is to wrap.
- (void)setup {
    self.editable = NO;
    self.usesSingleLineMode = YES;
    self.lineBreakMode = NSLineBreakByTruncatingTail;
}

@end