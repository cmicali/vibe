//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "MainWindow.h"
#import "NSURLUtil.h"
#import "MainPlayerController.h"

@implementation MainWindow

- (void)awakeFromNib {

    [self registerForDraggedTypes:@[
            NSPasteboardTypeFileURL,
            NSPasteboardTypeURL,
    ]];

    self.allowsConcurrentViewDrawing = YES;
    self.restorable = YES;
    self.restorationClass = [MainPlayerController class];

    self.styleMask = NSWindowStyleMaskBorderless |
                     NSWindowStyleMaskResizable |
                     NSWindowStyleMaskFullSizeContentView;

    [self setMovableByWindowBackground:YES];

    self.backgroundColor = [NSColor clearColor];

    self.opaque = NO;

    self.contentView.wantsLayer = YES;
    self.contentView.layer.cornerRadius = 26;
    self.contentView.layer.borderColor = [NSColor.blackColor colorWithAlphaComponent:0.5].CGColor;
    self.contentView.layer.borderWidth = 1;

    [self invalidateShadow];
    [self loadSettings];

}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (sender.draggingSource) {
        return NSDragOperationNone;
    }
    return NSDragOperationCopy;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if (sender.draggingSource) {
        return NSDragOperationNone;
    }
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSArray<NSURL*> *urls = [pboard readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (urls.count == 0) {
        return NO;
    }
    // Accept the drop immediately; expand directories off the main thread and
    // deliver the playable files via the main-thread completion.
    __weak MainWindow *weakSelf = self;
    [NSURLUtil expandAndFilterList:urls completion:^(NSArray<NSURL *> *expanded) {
        MainWindow *strongSelf = weakSelf;
        // Drop contained no playable audio (e.g. an empty folder). Don't
        // forward an empty list, which would clear the current playlist.
        if (strongSelf && expanded.count > 0) {
            [strongSelf.dropDelegate mainWindow:strongSelf filesDropped:expanded];
        }
    }];
    return YES;
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

- (BOOL)isPlaylistShown {
    return self.frame.size.height > 150;
}

- (IBAction)setSmallSize:(BOOL)animate {
    [self setHeight:150 animate:animate];
}

- (IBAction)setLargeSize:(BOOL)animate {
    [self setHeight:400 animate:animate];
}

- (IBAction)toggleSize:(id)sender {
    if (self.isPlaylistShown) {
        [self setSmallSize:YES];
    }
    else {
        [self setLargeSize:YES];
    }
}

- (void)loadSettings {
    if (Settings.isFirstLaunch) { // || !Settings.isPlaylistShown) {
        [self setSmallSize:NO];
    }
}

@end
