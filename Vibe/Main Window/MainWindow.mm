//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "MainWindow.h"
#import "NSURLUtil.h"
#import "MainPlayerController.h"
#import "PitchControlPanel.h"

// Width of the main content, matching MainPlayerWindow.xib. The window frame
// is derived from this (+ the pitch panel width when revealed) rather than
// read back, so a stale autosaved/restored width self-corrects on toggle.
static const CGFloat kMainContentWidth = 680;

@implementation MainWindow {
    BOOL _pitchPanelShown;
}

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

// Borderless windows return NO by default, which makes AppKit warn on every
// makeKeyWindow and can keep the window from receiving key events.
- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
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

- (BOOL)isPitchPanelShown {
    return _pitchPanelShown;
}

- (void)setPitchPanelShown:(BOOL)shown animate:(BOOL)animate {
    if (shown == _pitchPanelShown) {
        return;
    }
    _pitchPanelShown = shown;
    CGFloat width = kMainContentWidth + (shown ? kPitchPanelWidth : 0);
    // min/max track the toggle (the xib pins them at 680) so user resizes
    // can't reveal or crop the panel; they only constrain the resize cursor,
    // not setFrame, so order relative to the frame change doesn't matter.
    NSSize minSize = self.minSize;
    NSSize maxSize = self.maxSize;
    minSize.width = width;
    maxSize.width = width;
    self.minSize = minSize;
    self.maxSize = maxSize;
    NSRect frame = self.frame;
    frame.size.width = width;
    // Grow to the right, but keep the panel on-screen when the window sits
    // against the screen's right edge.
    NSRect screenRect = self.screen.visibleFrame;
    if (screenRect.size.width > 0 && NSMaxX(frame) > NSMaxX(screenRect)) {
        frame.origin.x = NSMaxX(screenRect) - frame.size.width;
    }
    [self setFrame:frame display:YES animate:animate];
}

- (void)loadSettings {
    if (Settings.isFirstLaunch) { // || !Settings.isPlaylistShown) {
        [self setSmallSize:NO];
    }
    // The autosaved frame may include the pitch panel from a previous session;
    // the panel always starts hidden, so normalize back to the content width.
    NSRect frame = self.frame;
    if (frame.size.width != kMainContentWidth) {
        frame.size.width = kMainContentWidth;
        [self setFrame:frame display:NO];
    }
}

@end
