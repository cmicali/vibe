//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "MainWindow.h"
#import "NSURLUtil.h"

@implementation MainWindow {

}

- (void)awakeFromNib {
    [self registerForDraggedTypes:@[
            NSPasteboardTypeFileURL,
            NSPasteboardTypeURL,
    ]];

    self.styleMask = NSWindowStyleMaskBorderless |
            NSWindowStyleMaskResizable |
            NSWindowStyleMaskFullSizeContentView
            ;
    [self setMovableByWindowBackground:YES];
    self.backgroundColor = [NSColor clearColor];
    self.opaque = NO;
    self.contentView.wantsLayer = YES;
    self.contentView.layer.cornerRadius = 5;
    self.contentView.layer.borderColor = [NSColor.blackColor colorWithAlphaComponent:0.5].CGColor;
    self.contentView.layer.borderWidth = 1;

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

@end