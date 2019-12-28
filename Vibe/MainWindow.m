//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "MainWindow.h"
#import "NSURLUtil.h"

#import <pop/POP.h>

@implementation MainWindow

- (void)awakeFromNib {

    [self registerForDraggedTypes:@[
            NSPasteboardTypeFileURL,
            NSPasteboardTypeURL,
    ]];

    self.styleMask = NSWindowStyleMaskBorderless |
                     NSWindowStyleMaskResizable |
                     NSWindowStyleMaskFullSizeContentView;

    [self setMovableByWindowBackground:YES];

    self.backgroundColor = [NSColor clearColor];

    self.opaque = NO;

    self.contentView.wantsLayer = YES;
    self.contentView.layer.cornerRadius = 5;
    self.contentView.layer.borderColor = [NSColor.blackColor colorWithAlphaComponent:0.5].CGColor;
    self.contentView.layer.borderWidth = 1;

//    self.contentView.frame = CGRectMake(0, 24, self.contentView.frame.size.width, self.contentView.frame.size.height);

    [self invalidateShadow];


}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return NSDragOperationCopy;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSArray<NSURL*> *urls = [pboard readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    urls = [NSURLUtil expandFileList:urls];
    urls = [urls filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary* bindings) {
        BOOL supported = NO;

        supported = supported || [[url.pathExtension lowercaseString] isEqualToString:@"mp3"];
        supported = supported || [[url.pathExtension lowercaseString] isEqualToString:@"mp2"];
        supported = supported || [[url.pathExtension lowercaseString] isEqualToString:@"aiff"];
        supported = supported || [[url.pathExtension lowercaseString] isEqualToString:@"aif"];
        supported = supported || [[url.pathExtension lowercaseString] isEqualToString:@"wav"];
        supported = supported || [[url.pathExtension lowercaseString] isEqualToString:@"flac"];
        supported = supported || [[url.pathExtension lowercaseString] isEqualToString:@"ogg"];

        return supported;
    }]];
    [self.dropDelegate mainWindow:self filesDropped:urls];
    return urls.count > 0;
}

- (void)setHeight:(CGFloat)height animate:(BOOL)animate {
    CGFloat delta = height - self.frame.size.height;
    if (delta != 0) {
        CGRect frame = self.frame;
        frame.origin.y -= delta;
        frame.size.height += delta;
        [self setFrame:frame display:NO animate:animate];
    }
}

- (IBAction)setSmallSize:(BOOL)animate {
    [self setHeight:150 animate:YES];
}

- (IBAction)setLargeSize:(BOOL)animate {
    [self setHeight:400 animate:YES];
}

- (IBAction)toggleSize:(id)sender {
    if (self.frame.size.height > 150) {
        [self setSmallSize:YES];
    }
    else {
        [self setLargeSize:YES];
    }
}


@end
