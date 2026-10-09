//
//  MainWindow.m
//  Vibe
//

#import "MainWindow.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "WindowAnimation.h"
#import "AppDelegate.h" // drops enter the app's one open funnel; see performDragOperation:
#import "LinkRules.h"
#import "MainPlayerController.h"
#import "PitchControlPanel.h"
#import "VibeStrings.h"

// The frame belongs to the user, kept by the autosave. This class enforces
// only the floors and the drag band (restingHeightForDraggedHeight:), and
// applies the app's own resizes.

static NSString *const kFrameAutosaveName = @"VibeMainWindow";

@implementation MainWindow {
    BOOL _pitchPanelShown;
    BOOL _playlistShown;
    id   _resizeObserver;
    // The drag in progress, decided once at its entry.
    NSDragOperation _dragOperation;
}

// Keep the controller's conversion guards when Undo follows the responder chain.
- (IBAction)undo:(id)sender {
    [NSApp sendAction:@selector(undo:) to:self.windowController from:sender];
}

- (IBAction)redo:(id)sender {
    [NSApp sendAction:@selector(redo:) to:self.windowController from:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(undo:) || item.action == @selector(redo:)) {
        return [(id<NSMenuItemValidation>)self.windowController validateMenuItem:item];
    }
    return [super validateMenuItem:item];
}

- (instancetype)init {
    self = [super initWithContentRect:NSMakeRect(206, 444, kMainWindowContentWidth, kMainWindowDesignHeight)
                            styleMask:NSWindowStyleMaskBorderless |
                                      NSWindowStyleMaskResizable |
                                      NSWindowStyleMaskMiniaturizable |
                                      NSWindowStyleMaskFullSizeContentView
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        __weak MainWindow *weakSelf = self;
        // A borderless window draws no title bar, so this only ever reaches
        // accessibility and the Window menu.
        self.title = VibeAppName();
        self.identifier = @"main_window";
        self.releasedWhenClosed = NO;
        // Floors only; loadSettings re-applies the width floor once the
        // pitch-panel state is known.
        self.minSize = NSMakeSize(kMainWindowMinContentWidth, kMainWindowSmallHeight);
        self.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        self.tabbingMode = NSWindowTabbingModeDisallowed;
        self.autorecalculatesKeyViewLoop = NO;
        self.allowsToolTipsWhenApplicationIsInactive = NO;

        // Files, and web links (System/Remote/AGENTS.md). Entering decides
        // whether the drag holds either.
        [self registerForDraggedTypes:@[
            kVibeDropTypeFileURL,
            kVibeDropTypeURL,
            kVibeDropTypeText,
        ]];

        self.allowsConcurrentViewDrawing = YES;
        self.restorable = YES;
        self.restorationClass = [MainPlayerController class];

        [self setMovableByWindowBackground:YES];

        self.backgroundColor = [NSColor clearColor];

        self.opaque = NO;

        self.contentView.wantsLayer = YES;
        self.contentView.focusRingType = NSFocusRingTypeNone;
        // Load-bearing without masksToBounds: AppKit shapes the window from
        // this radius.
        self.contentView.layer.cornerRadius = AppSettings.sharedInstance.currentTheme.resolvedWindowCornerRadius;

        // loadSettings reconciles the restored frame with the shown flags.
        if (![self setFrameUsingName:kFrameAutosaveName]) {
            [self center];
        }
        self.frameAutosaveName = kFrameAutosaveName;

        [self invalidateShadow];
        [self loadSettings];

        // A drag-resize can reveal or collapse the playlist without the toggle.
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
        // Auto-removed at dealloc, like every selector-based observer.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(keepLockedWindowOnScreen)
                                                     name:NSApplicationDidChangeScreenParametersNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    if (_resizeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_resizeObserver];
    }
}

- (void)syncPlaylistShownFromHeight {
    BOOL shown = (self.frame.size.height > kMainWindowSmallHeight);
    if (shown != _playlistShown) {
        _playlistShown = shown;
        AppSettings.sharedInstance.playlistShown = shown;
    }
}

// Borderless windows default to NO, which stops key events.
- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}

#pragma mark - Position lock

// TRAP: from macOS 26 this ignores isMovable, so the waveform's handoff would
// move a locked window. The lock is enforced here for every caller.
- (void)performWindowDragWithEvent:(NSEvent *)event {
    if (self.isMovable) {
        [super performWindowDragWithEvent:event];
    }
}

// TRAP: the system never moves a non-movable window when displays change
// (NSWindow.h, isMovable), so a locked window could be stranded off every
// screen. Screens are tested directly: self.screen is unreliable right after a
// reconfiguration.
- (void)keepLockedWindowOnScreen {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (self.isMovable || screens.count == 0) {
        return;
    }
    NSRect frame = self.frame;
    for (NSScreen *screen in screens) {
        if (NSIntersectsRect(screen.visibleFrame, frame)) {
            return;
        }
    }
    // The top edge (traffic lights, transport) never above the visible area.
    NSRect visible = screens.firstObject.visibleFrame;
    frame.origin.x = NSMidX(visible) - NSWidth(frame) / 2;
    frame.origin.y = MIN(NSMidY(visible) - NSHeight(frame) / 2, NSMaxY(visible) - NSHeight(frame));
    [self setFrame:frame display:YES];
}

#pragma mark - Drag and Drop

static NSArray<NSDictionary<NSString *, NSString *> *> *VibeDropItemsOfPasteboard(NSPasteboard *pboard) {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *items = [NSMutableArray array];
    for (NSPasteboardItem *item in pboard.pasteboardItems) {
        NSMutableDictionary<NSString *, NSString *> *strings = [NSMutableDictionary dictionary];
        for (NSString *type in @[kVibeDropTypeFileURL, kVibeDropTypeURL, kVibeDropTypeText]) {
            NSString *string = [item stringForType:type];
            if (string) {
                strings[type] = string;
            }
        }
        [items addObject:strings];
    }
    return items;
}

// External drags only: our own sources (the art, a playlist row) carry file
// URLs a drop here would re-open. A drag holding no file and no web link is
// refused.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    _dragOperation = !sender.draggingSource
            && VibeDropURLsOfItems(VibeDropItemsOfPasteboard(sender.draggingPasteboard)).count > 0
            ? NSDragOperationCopy : NSDragOperationNone;
    return [self draggingUpdated:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if (_dragOperation != NSDragOperationNone) {
        [self notifyFileDraggingUpdated:sender];
    }
    return _dragOperation;
}

- (void)draggingExited:(nullable id<NSDraggingInfo>)sender {
    [self notifyFileDraggingEnded];
}

// After every session; performDragOperation runs first, so a drop resolves its
// well before this tears the presentation down.
- (void)draggingEnded:(id<NSDraggingInfo>)sender {
    [self notifyFileDraggingEnded];
}

- (void)notifyFileDraggingUpdated:(id<NSDraggingInfo>)sender {
    [self.dropDelegate mainWindow:self fileDraggingUpdatedAtLocation:sender.draggingLocation];
}

- (void)notifyFileDraggingEnded {
    [self.dropDelegate mainWindowFileDraggingEnded:self];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    // Synchronously: the session is gone by the time the expansion lands.
    BOOL append = [self.dropDelegate mainWindow:self dropAppendsAtLocation:sender.draggingLocation];
    return [self openDroppedItems:VibeDropItemsOfPasteboard(sender.draggingPasteboard) appending:append];
}

- (BOOL)openDroppedItems:(NSArray<NSDictionary<NSString *, NSString *> *> *)items appending:(BOOL)append {
    NSArray<NSURL *> *dropped = VibeDropURLsOfItems(items);
    if (dropped.count == 0) {
        return NO;
    }
    // TRAP: a Finder drag delivers file-reference URLs (file:///.file/id=…),
    // whose .path follows the file wherever it moves. Downstream treats a
    // track's URL as fixed — cache keys hash it, the convert undo restores to
    // it — so every drop is pinned to its current path.
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:dropped.count];
    for (NSURL *url in dropped) {
        NSString *path = url.isFileURL ? url.path : nil;
        [urls addObject:path ? [NSURL fileURLWithPath:path] : url];
    }
    // The whole open funnel, or a drop skips a tail step such as
    // revealEmptyStateNamingPlaylist:.
    [(AppDelegate *)NSApp.delegate openDroppedURLs:urls appending:append];
    return YES;
}

// Escape: a dropped link stops resolving, and its drop opens nothing.
- (void)cancelOperation:(id)sender {
    if (![(AppDelegate *)NSApp.delegate cancelLinkOpens]) {
        [super cancelOperation:sender];
    }
}

#pragma mark - Public API

// The rationale is in Util/WindowAnimation.h; the settings window shares it.
- (NSTimeInterval)animationResizeTime:(NSRect)newFrame {
    return kWindowResizeAnimationDuration;
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
    return _playlistShown;
}

- (void)setSmallSize:(BOOL)animate {
    _playlistShown = NO;
    AppSettings.sharedInstance.playlistShown = NO;
    [self setHeight:kMainWindowSmallHeight animate:animate];
}

- (void)setLargeSize:(BOOL)animate {
    _playlistShown = YES;
    AppSettings.sharedInstance.playlistShown = YES;
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

// No height between collapsed and the shortest useful playlist
// (kPlaylistPaneMinHeight) is worth resting at, so a drag lands on the nearer
// end. minSize stays at the collapsed height, which the toggle targets.
- (CGFloat)restingHeightForDraggedHeight:(CGFloat)height {
    if (height <= kMainWindowSmallHeight || height >= kMainWindowMinLargeHeight) {
        return height;
    }
    CGFloat midpoint = (kMainWindowSmallHeight + kMainWindowMinLargeHeight) / 2;
    return height < midpoint ? kMainWindowSmallHeight : kMainWindowMinLargeHeight;
}

- (CGFloat)contentWidth {
    return self.frame.size.width - (_pitchPanelShown ? kPitchPanelWidth : 0);
}

// Grows to the right off the fixed left edge, like dragging the resize handle.
- (void)setContentWidth:(CGFloat)width animate:(BOOL)animate {
    NSRect frame = self.frame;
    frame.size.width = MAX(self.minSize.width,
                           width + (_pitchPanelShown ? kPitchPanelWidth : 0));
    if (frame.size.width == self.frame.size.width) {
        return;
    }
    [self setFrame:[self frameKeptOnScreen:frame] display:YES animate:animate];
}

// Slides back, but never past the left edge (traffic lights, transport). A
// locked window stays put.
- (NSRect)frameKeptOnScreen:(NSRect)frame {
    NSRect screenRect = self.screen.visibleFrame;
    if (self.isMovable && screenRect.size.width > 0 && NSMaxX(frame) > NSMaxX(screenRect)) {
        frame.origin.x = MAX(NSMinX(screenRect), NSMaxX(screenRect) - frame.size.width);
    }
    return frame;
}

- (BOOL)isPitchPanelShown {
    return _pitchPanelShown;
}

// The panel moves the width floor: the body must still fit
// kMainWindowMinContentWidth beside it. Returns the new floor.
- (CGFloat)applyMinWidthForPitchPanelShown:(BOOL)shown {
    NSSize minSize = self.minSize;
    minSize.width = kMainWindowMinContentWidth + (shown ? kPitchPanelWidth : 0);
    self.minSize = minSize;
    return minSize.width;
}

- (void)setPitchPanelShown:(BOOL)shown animate:(BOOL)animate {
    if (shown == _pitchPanelShown) {
        return;
    }
    _pitchPanelShown = shown;
    AppSettings.sharedInstance.pitchPanelShown = shown;
    CGFloat minWidth = [self applyMinWidthForPitchPanelShown:shown];
    NSRect frame = self.frame;
    // By exactly the slice: the body keeps the user's width.
    frame.size.width = MAX(minWidth,
                           frame.size.width + (shown ? kPitchPanelWidth : -kPitchPanelWidth));
    [self setFrame:[self frameKeptOnScreen:frame] display:YES animate:animate];
}

// The shipping shape, not position, so anchored at the top-left. Writes both
// settings rather than trusting the cleared store, and saves the frame.
- (void)resetToDefaultShape {
    _playlistShown = NO;
    AppSettings.sharedInstance.playlistShown = NO;
    _pitchPanelShown = NO;
    AppSettings.sharedInstance.pitchPanelShown = NO;

    NSRect frame = self.frame;
    frame.origin.y += frame.size.height - kMainWindowSmallHeight;
    frame.size = NSMakeSize(MAX(kMainWindowContentWidth, [self applyMinWidthForPitchPanelShown:NO]),
                            kMainWindowSmallHeight);
    [self setFrame:[self frameKeptOnScreen:frame] display:YES animate:NO];
    [self saveFrameUsingName:kFrameAutosaveName];
}

// Both shown states are explicit settings: a first launch has no saved frame,
// and a resizable width does not identify the panel state. The restored width
// already includes a shown panel, so only the floor is enforced.
- (void)loadSettings {
    NSRect frame = self.frame;

    _playlistShown = AppSettings.sharedInstance.isPlaylistShown;
    CGFloat height = frame.size.height;
    if (!_playlistShown) {
        height = kMainWindowSmallHeight;
    }
    else if (height <= kMainWindowSmallHeight) {
        height = kMainWindowLargeHeight; // shown, but the restored height is collapsed/missing
    }
    else {
        // Never inside the drag band, which a saved frame can still land in.
        height = MAX(height, kMainWindowMinLargeHeight);
    }
    frame.origin.y -= height - frame.size.height; // top edge fixed, like setHeight:

    frame.size.height = height;

    // Never restored while the fader is disallowed (bit-perfect output).
    _pitchPanelShown = AppSettings.sharedInstance.isPitchPanelShown
            && AppSettings.sharedInstance.pitchControlAllowed;
    frame.size.width = MAX(frame.size.width,
                           [self applyMinWidthForPitchPanelShown:_pitchPanelShown]);

    if (!NSEqualRects(frame, self.frame)) {
        [self setFrame:frame display:NO];
    }
}

@end
