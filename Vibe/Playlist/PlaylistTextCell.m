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

- (void)setup {
    self.editable = NO;
}

- (NSRect)drawingRectForBounds:(NSRect)rect {
    return [super drawingRectForBounds:rect];
}

@end