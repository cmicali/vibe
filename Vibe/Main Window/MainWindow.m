//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "MainWindow.h"
#import "NSURLUtil.h"
#import "MainPlayerController.h"
#import "PitchControlPanel.h"
#import "Strings.h"

// The window frame is derived from kMainWindowContentWidth (+ the pitch panel
// width when revealed) rather than read back, so a stale autosaved/restored
// width self-corrects on toggle. The layout constants live in Constants.h
// (imported via MainWindow.h), shared with MainPlayerContentView.

static NSString *const kFrameAutosaveName = @"VibeMainWindow";

@implementation MainWindow {
    BOOL _pitchPanelShown;
    BOOL _playlistShown;
    id   _resizeObserver;
}

- (instancetype)init {
    self = [super initWithContentRect:NSMakeRect(206, 444, kMainWindowContentWidth, 350)
                            styleMask:NSWindowStyleMaskBorderless |
                                      NSWindowStyleMaskResizable |
                                      NSWindowStyleMaskMiniaturizable |
                                      NSWindowStyleMaskFullSizeContentView
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        // A borderless window draws no title bar, so this only ever reaches
        // accessibility and the Window menu.
        self.title = STR_APP_NAME;
        self.identifier = @"main_window";
        self.releasedWhenClosed = NO;
        self.minSize = NSMakeSize(kMainWindowContentWidth, kMainWindowSmallHeight);
        self.maxSize = NSMakeSize(kMainWindowContentWidth, kMainWindowMaxHeight);
        self.tabbingMode = NSWindowTabbingModeDisallowed;
        self.autorecalculatesKeyViewLoop = NO;
        self.allowsToolTipsWhenApplicationIsInactive = NO;

        // File URLs only: performDragOperation reads with FileURLsOnly, so
        // also registering NSPasteboardTypeURL would show a copy cursor for a
        // browser-link drag the drop then rejects.
        [self registerForDraggedTypes:@[
            NSPasteboardTypeFileURL,
        ]];

        self.allowsConcurrentViewDrawing = YES;
        self.restorable = YES;
        self.restorationClass = [MainPlayerController class];

        [self setMovableByWindowBackground:YES];

        self.backgroundColor = [NSColor clearColor];

        self.opaque = NO;

        self.contentView.wantsLayer = YES;
        self.contentView.focusRingType = NSFocusRingTypeNone;
        // No explicit border: the system shadow and the glass backdrop's own
        // rim lighting supply the edge, like standard windows (a drawn dark
        // outline reads wrong in light mode).
        // LOAD-BEARING despite the absent masksToBounds: AppKit shapes the
        // window from this radius — without it the corners render square.
        self.contentView.layer.cornerRadius = kMainWindowCornerRadius;

        // Adopt the previous session's frame, then keep saving under the same
        // name. loadSettings reconciles the frame with the persisted
        // playlist/pitch-panel shown flags.
        if (![self setFrameUsingName:kFrameAutosaveName]) {
            [self center];
        }
        self.frameAutosaveName = kFrameAutosaveName;

        [self invalidateShadow];
        [self loadSettings];

        // A manual drag-resize can reveal or collapse the playlist without
        // going through the toggle; keep the flag and its setting in sync.
        __weak MainWindow *weakSelf = self;
        _resizeObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:NSWindowDidEndLiveResizeNotification
                            object:self
                             queue:nil
                        usingBlock:^(NSNotification *note) {
                            MainWindow *strongSelf = weakSelf;
                            if (strongSelf) {
                                [strongSelf syncPlaylistShownFromHeight];
                            }
                        }];
    }
    return self;
}

- (void)dealloc {
    if (_resizeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_resizeObserver];
    }
}

// No performClose: override — ⌘W is the player's closeFile: (it closes the
// loaded files, not the window), and nothing sends performClose:.

- (void)syncPlaylistShownFromHeight {
    BOOL shown = (self.frame.size.height > kMainWindowSmallHeight);
    if (shown != _playlistShown) {
        _playlistShown = shown;
        Settings.playlistShown = shown;
    }
}

// Borderless windows return NO by default, which makes AppKit warn on every
// makeKeyWindow and can keep the window from receiving key events.
- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}

#pragma mark - Drag and Drop

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

#pragma mark - Public API

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
    return _playlistShown;
}

- (void)setSmallSize:(BOOL)animate {
    _playlistShown = NO;
    Settings.playlistShown = NO;
    [self setHeight:kMainWindowSmallHeight animate:animate];
}

- (void)setLargeSize:(BOOL)animate {
    _playlistShown = YES;
    Settings.playlistShown = YES;
    [self setHeight:kMainWindowLargeHeight animate:animate];
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

// Window width is a pure function of the pitch-panel state; min/max are
// pinned to it so user resizes can't reveal or crop the panel (they only
// constrain the resize cursor, not setFrame, so ordering doesn't matter).
// Both the toggle and the settings-restore derive their frame width here;
// how the frame is applied (animated vs silent) stays with the caller.
- (CGFloat)applyContentWidthForPitchPanelShown:(BOOL)shown {
    CGFloat width = kMainWindowContentWidth + (shown ? kPitchPanelWidth : 0);
    NSSize minSize = self.minSize;
    NSSize maxSize = self.maxSize;
    minSize.width = width;
    maxSize.width = width;
    self.minSize = minSize;
    self.maxSize = maxSize;
    return width;
}

- (void)setPitchPanelShown:(BOOL)shown animate:(BOOL)animate {
    if (shown == _pitchPanelShown) {
        return;
    }
    _pitchPanelShown = shown;
    Settings.pitchPanelShown = shown;
    NSRect frame = self.frame;
    frame.size.width = [self applyContentWidthForPitchPanelShown:shown];
    // Grow to the right, but keep the panel on-screen when the window sits
    // against the screen's right edge.
    NSRect screenRect = self.screen.visibleFrame;
    if (screenRect.size.width > 0 && NSMaxX(frame) > NSMaxX(screenRect)) {
        frame.origin.x = NSMaxX(screenRect) - frame.size.width;
    }
    [self setFrame:frame display:YES animate:animate];
}

// Both shown states are persisted as explicit settings rather than riding on
// the autosaved frame: NSWindow quietly normalizes the saved width, and a
// first launch has no saved frame at all (the registered defaults — both
// hidden — supply the first-launch size).
- (void)loadSettings {
    NSRect frame = self.frame;

    _playlistShown = Settings.isPlaylistShown;
    CGFloat height = frame.size.height;
    if (!_playlistShown) {
        height = kMainWindowSmallHeight;
    }
    else if (height <= kMainWindowSmallHeight) {
        height = kMainWindowLargeHeight; // shown, but the restored height is collapsed/missing
    }
    // else: shown — keep the user's custom restored height.
    frame.origin.y -= height - frame.size.height; // top edge fixed, like setHeight:

    frame.size.height = height;

    _pitchPanelShown = Settings.isPitchPanelShown;
    frame.size.width = [self applyContentWidthForPitchPanelShown:_pitchPanelShown];

    if (!NSEqualRects(frame, self.frame)) {
        [self setFrame:frame display:NO];
    }
}

@end
