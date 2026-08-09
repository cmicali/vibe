//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "MainWindow.h"
#import "NSURLUtil.h"
#import "MainPlayerController.h"
#import "PitchControlPanel.h"

// The window is freely resizable in both axes, and the frame belongs to the
// user, kept by the autosave. This class enforces only the floors —
// kMainWindowMinContentWidth, plus the pitch panel's slice while it is
// showing, and kMainWindowSmallHeight, with the band above that height closed
// to a drag (restingHeightForDraggedHeight:) — and applies the two size changes
// the app makes itself: the playlist toggle's height and the pitch panel's
// kPitchPanelWidth either way. The layout constants live in Constants.h,
// imported through MainWindow.h and shared with MainPlayerContentView.

static NSString *const kFrameAutosaveName = @"VibeMainWindow";

@implementation MainWindow {
    BOOL _pitchPanelShown;
    BOOL _playlistShown;
    id   _resizeObserver;
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
        self.title = @"Vibe";
        self.identifier = @"main_window";
        self.releasedWhenClosed = NO;
        // Floors only; loadSettings re-applies the width floor once the
        // pitch-panel state is known. There is no ceiling, because AppKit
        // already keeps a drag-resize inside the screen.
        self.minSize = NSMakeSize(kMainWindowMinContentWidth, kMainWindowSmallHeight);
        self.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        self.tabbingMode = NSWindowTabbingModeDisallowed;
        self.autorecalculatesKeyViewLoop = NO;
        self.allowsToolTipsWhenApplicationIsInactive = NO;

        // File URLs only. performDragOperation reads with FileURLsOnly, so
        // registering NSPasteboardTypeURL as well would show a copy cursor for
        // a browser-link drag that the drop then rejects.
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
        // No explicit border. The system shadow and the glass backdrop's own
        // rim lighting supply the edge, as on standard windows; a drawn dark
        // outline reads wrong in light mode.
        //
        // This radius is load-bearing despite the absent masksToBounds: AppKit
        // shapes the window from it, and without it the corners render square.
        self.contentView.layer.cornerRadius = kMainWindowCornerRadius;

        // Adopt the previous session's frame, then keep saving under the same
        // name. loadSettings reconciles the frame with the persisted flags for
        // whether the playlist and pitch panel are shown.
        if (![self setFrameUsingName:kFrameAutosaveName]) {
            [self center];
        }
        self.frameAutosaveName = kFrameAutosaveName;

        [self invalidateShadow];
        [self loadSettings];

        // A manual drag-resize can reveal or collapse the playlist without
        // going through the toggle, so keep the flag and its setting in sync.
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

// There is no performClose: override. ⌘W is the player's closeFile:, which
// closes the loaded files rather than the window, and nothing sends
// performClose:.

- (void)syncPlaylistShownFromHeight {
    BOOL shown = (self.frame.size.height > kMainWindowSmallHeight);
    if (shown != _playlistShown) {
        _playlistShown = shown;
        Settings.playlistShown = shown;
    }
}

// Borderless windows return NO by default, which makes AppKit warn on every
// makeKeyWindow and can stop the window receiving key events.
- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}

#pragma mark - Drag and Drop

// External file drags only. A draggingSource means one of our own views is the
// source, namely the album art's drag-out. The delegate is kept abreast of the
// drag's position, so that the playlist's empty-state wells can track the
// cursor.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if (sender.draggingSource) {
        return NSDragOperationNone;
    }
    [self notifyFileDraggingUpdated:sender];
    return NSDragOperationCopy;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if (sender.draggingSource) {
        return NSDragOperationNone;
    }
    [self notifyFileDraggingUpdated:sender];
    return NSDragOperationCopy;
}

- (void)draggingExited:(nullable id<NSDraggingInfo>)sender {
    [self notifyFileDraggingEnded];
}

// Fires after every session ends, drop or no drop. performDragOperation runs
// first, so a drop resolves its well before this tears the presentation down.
- (void)draggingEnded:(id<NSDraggingInfo>)sender {
    [self notifyFileDraggingEnded];
}

- (void)notifyFileDraggingUpdated:(id<NSDraggingInfo>)sender {
    if ([self.dropDelegate respondsToSelector:@selector(mainWindow:fileDraggingUpdatedAtLocation:)]) {
        [self.dropDelegate mainWindow:self fileDraggingUpdatedAtLocation:sender.draggingLocation];
    }
}

- (void)notifyFileDraggingEnded {
    if ([self.dropDelegate respondsToSelector:@selector(mainWindowFileDraggingEnded:)]) {
        [self.dropDelegate mainWindowFileDraggingEnded:self];
    }
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSArray<NSURL*> *pasteboardURLs = [pboard readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (pasteboardURLs.count == 0) {
        return NO;
    }
    // TRAP: a Finder drag delivers file-reference URLs (file:///.file/id=…),
    // whose .path re-resolves to wherever the file currently is. Everything
    // downstream treats a track's URL as a fixed path — cache keys hash it,
    // and the convert-undo record restores to it — so pin every drop to the
    // path it has right now.
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:pasteboardURLs.count];
    for (NSURL *url in pasteboardURLs) {
        NSString *path = url.path;
        [urls addObject:path ? [NSURL fileURLWithPath:path] : url];
    }
    // The drop point decides which empty-state well, if any, was hit. It is
    // captured now, because the delivery below is async and the session has
    // gone by then.
    NSPoint location = sender.draggingLocation;
    // Accept the drop immediately, expand directories off the main thread, and
    // deliver the playable files through the main-thread completion.
    __weak MainWindow *weakSelf = self;
    [NSURLUtil expandAndFilterList:urls completion:^(NSArray<NSURL *> *expanded) {
        MainWindow *strongSelf = weakSelf;
        // The drop contained no playable audio, as an empty folder would not.
        // Do not forward an empty list, which would clear the current playlist.
        if (strongSelf && expanded.count > 0 &&
            [strongSelf.dropDelegate respondsToSelector:@selector(mainWindow:filesDropped:atLocation:)]) {
            [strongSelf.dropDelegate mainWindow:strongSelf filesDropped:expanded atLocation:location];
        }
    }];
    return YES;
}

#pragma mark - Public API

// Every animated resize the app performs — the playlist toggle, the pitch
// panel reveal, the View > Size presets — runs at this one duration. AppKit's
// default scales with the distance, at roughly 0.2s per 150pt, which makes the
// playlist's 250pt jump drag at about 0.27s and would put a Large-to-Small
// preset near a full second. These are chrome snapping to a new shape rather
// than content transitions, so a short fixed time reads better and stays
// consistent whatever the distance.
static const NSTimeInterval kWindowResizeAnimationDuration = 0.12;

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

// Between the collapsed layout and the shortest playlist worth showing there is
// no height worth resting at: the pane becomes a sliver, and the empty state
// degrades from a cramped drop well to a blank strip once the well hides itself
// (kPlaylistPaneMinHeight). So the band is closed rather than merely
// discouraged — a drag through it lands on whichever end it is nearer, which
// reads as the playlist snapping shut and springing back open under the cursor.
//
// minSize keeps its floor at the collapsed height, since both the toggle and
// the settings restore target that exactly; this rule constrains only the drag.
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

// A window grown at the right edge can end up hanging off the screen, where
// the part the growth was for isn't visible; slide it back, but never so far
// that the left edge (traffic lights, transport) goes off the other side.
- (NSRect)frameKeptOnScreen:(NSRect)frame {
    NSRect screenRect = self.screen.visibleFrame;
    if (screenRect.size.width > 0 && NSMaxX(frame) > NSMaxX(screenRect)) {
        frame.origin.x = MAX(NSMinX(screenRect), NSMaxX(screenRect) - frame.size.width);
    }
    return frame;
}

- (BOOL)isPitchPanelShown {
    return _pitchPanelShown;
}

// The panel is a fixed-width slice of a resizable window, so it moves the
// width floor rather than fixing the width: the body still has to fit
// kMainWindowMinContentWidth beside it. Returns the new floor, which both the
// toggle and the settings-restore clamp their frame against.
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
    Settings.pitchPanelShown = shown;
    CGFloat minWidth = [self applyMinWidthForPitchPanelShown:shown];
    NSRect frame = self.frame;
    // Widen/narrow by exactly the panel's slice: the body keeps whatever width
    // the user resized it to.
    frame.size.width = MAX(minWidth,
                           frame.size.width + (shown ? kPitchPanelWidth : -kPitchPanelWidth));
    // Grow to the right, but keep the panel on-screen when the window sits
    // against the screen's right edge.
    [self setFrame:[self frameKeptOnScreen:frame] display:YES animate:animate];
}

// Both shown states are persisted as explicit settings rather than inferred
// from the autosaved frame: a first launch has no saved frame at all (the
// registered defaults — both hidden — supply the first-launch size), and with
// a freely resizable window the saved width no longer identifies the panel
// state. The restored width already includes the panel when it was showing at
// save time (the toggle resizes the window and the autosave follows), so the
// width itself is the user's — only the floor is enforced here.
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
    else {
        // Shown: the user's own restored height, but never inside the band the
        // drag snap keeps them out of. A frame saved before that floor existed
        // can still land there.
        height = MAX(height, kMainWindowMinLargeHeight);
    }
    frame.origin.y -= height - frame.size.height; // top edge fixed, like setHeight:

    frame.size.height = height;

    _pitchPanelShown = Settings.isPitchPanelShown;
    frame.size.width = MAX(frame.size.width,
                           [self applyMinWidthForPitchPanelShown:_pitchPanelShown]);

    if (!NSEqualRects(frame, self.frame)) {
        [self setFrame:frame display:NO];
    }
}

@end
