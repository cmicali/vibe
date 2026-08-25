//
//  MainPlayerController+Window.m
//  Vibe
//

#import "MainPlayerController+Window.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Settings.h"

#import "AppDelegate.h"
#import "AppSettings.h"
#import "AudioPlayer.h"
#import "MainMenuBuilder.h" // vends the context-menu items shared with the main menu
#import "MainPlayerContentView.h"
#import "MainWindow.h"
#import "MenuValidationRules.h"
#import "PitchControlPanel.h"
#import "PlaylistController.h"
#import "PlaylistTableView.h"
#import "SymbolButton.h"
#import "TrackDisplayController.h"
#import "UIUpdateTimer.h"
#import "VibeStrings.h"

@implementation MainPlayerController (Window)

#pragma mark - Construction

- (void)buildContentInWindow:(MainWindow *)window {
    NSView *contentView = window.contentView;
    // The backdrop, spanning the whole window with the pitch panel included;
    // everything else composites over it. On macOS 26 it is Liquid Glass in
    // the Control Center style, its corner radius matching the contentView
    // layer mask so the rim lighting follows the window shape. Before macOS
    // 26, where Liquid Glass does not exist, a frosted behind-window blur
    // stands in, shaped by maskImage — the blur region ignores a layer radius.
    NSView *backdrop;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:contentView.bounds];
        glass.cornerRadius = kMainWindowCornerRadius;
        // Clear, rather than Regular, keeps the backdrop legible as glass
        // rather than a frosted wall: more of what is behind the window shows
        // through.
        glass.style = NSGlassEffectViewStyleClear;
        backdrop = glass;
    }
    else {
        NSVisualEffectView *frost = [[NSVisualEffectView alloc] initWithFrame:contentView.bounds];
        frost.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        frost.state = NSVisualEffectStateActive; // key-state-independent, like the playlist frost
        frost.material = NSVisualEffectMaterialUnderWindowBackground;
        frost.maskImage = [MainPlayerContentView frostCornerMaskWithRadius:kMainWindowCornerRadius];
        backdrop = frost;
    }
    backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [contentView addSubview:backdrop];
    MainPlayerContentView *content = [[MainPlayerContentView alloc] initWithTarget:self];
    [content setTrafficLightsShown:AppSettings.sharedInstance.showTrafficLights];
    self.playerContentView = content;
    [contentView addSubview:content];
    // The window already carries the restored, autosaved frame. Setting the
    // body frame here runs the subview autoresizing pass at the real size,
    // which is where the design-time frames in MainPlayerContentView stretch
    // to the user's width.
    content.frame = [self playerBodyFrame];

    self.playButton = content.playButton;
    self.nextButton = content.nextButton;
    self.waveformView = content.waveformView;
    self.playlistTableView = content.playlistTableView;

    // The header labels and the waveform's rendering states live behind the
    // track display. This controller keeps only the outlets it drives itself.
    self.trackDisplay = [[TrackDisplayController alloc] initWithContentView:content];

    // The right time label toggles between remaining and total on a click,
    // persisted in AppSettings. It uses a gesture recognizer rather than a
    // button, so the label stays a plain text field, styled with its row.
    NSClickGestureRecognizer *timeModeClick =
            [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(toggleTimeDisplayMode:)];
    [content.totalTimeTextField addGestureRecognizer:timeModeClick];

    // A right-click menu on the whole window body. It is on the content view,
    // so the responder chain carries it to the pitch panel too. Every item
    // acts on the current track; the Copy and Convert items are the ones
    // MainMenuBuilder vends for the main menu, so they share its identifiers
    // and so their validation (and the Convert retitling).
    // Menu title never drawn — a context menu shows only its items.
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:VibeNotLocalized(@"Popup Menu")];
    [contextMenu addItem:[MainMenuBuilder symbolItemWithTitle:STR_MENU_SHOW_IN_FINDER
                                                   symbolName:@"folder"
                                                       action:@selector(showInFinder:)
                                                       target:self
                                                   identifier:@"show_in_finder"]];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    [contextMenu addItem:[MainMenuBuilder copyNameItemWithTarget:self]];
    [contextMenu addItem:[MainMenuBuilder copyFileItemWithTarget:self]];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    [contextMenu addItem:[MainMenuBuilder convertToFLACItemWithTarget:self]];
    contentView.menu = contextMenu;
    // PlaylistController installs the playlist table's own row context menu,
    // which shadows this window-wide one, when the table is attached.
}

// The autoresizing masks reproduce both frames through a drag-resize; these
// compute them outright for the build, and after a pitch-panel toggle.
- (NSRect)playerBodyFrame {
    NSRect frame = self.window.contentView.bounds;
    if (((MainWindow *)self.window).isPitchPanelShown) {
        frame.size.width -= kPitchPanelWidth;
    }
    return frame;
}

- (NSRect)pitchPanelFrame {
    NSRect bounds = self.window.contentView.bounds;
    CGFloat x = NSMaxX(bounds) - (((MainWindow *)self.window).isPitchPanelShown ? kPitchPanelWidth : 0);
    return NSMakeRect(x, 0, kPitchPanelWidth, bounds.size.height);
}

// A contentView sibling of the player body rather than a child of
// MainPlayerContentView: it is revealed by widening the window past the body,
// and its size comes from the window's restored frame, not the design size.
// It is right-anchored, with a fixed width and a flexible left margin, so a
// drag-resize keeps it on the right edge, or, while hidden, keeps it parked
// the same distance past it. heightSizable tracks the small-large layout
// toggle.
- (void)buildPitchPanel {
    NSView *contentView = self.window.contentView;
    _pitchPanel = [[PitchControlPanel alloc] initWithFrame:[self pitchPanelFrame]];
    _pitchPanel.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    _pitchPanel.delegate = self;
    [contentView addSubview:_pitchPanel];
    [self applyPitchRange];
}

- (void)windowWillClose:(NSNotification *)notification {
    [NSApp terminate:nil];
}

- (BOOL)isWindowVisible {
    return (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    // Revealed mid-playback, so refresh once now rather than waiting a tick.
    if (_uiTimer.wanted && [self isWindowVisible]) {
        [self updateUI];
    }
    _uiTimer.windowVisible = [self isWindowVisible];
    [self syncEqualizerActivity];
}

// The window's own height rule, applied to drags only: the app's animated
// resizes, the playlist toggle above all, must pass through untouched, and this
// is the one place that can tell the two apart. Every height the app itself sets
// is a fixed point of the rule anyway; the gate keeps an animation's
// intermediate frames from being snapped mid-flight.
- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize {
    if (sender.inLiveResize) {
        frameSize.height = [(MainWindow *)sender restingHeightForDraggedHeight:frameSize.height];
    }
    return frameSize;
}

// The title's shrink-to-fit depends on the width of its width-flexible label.
// Live-drag frames are skipped, so no text is measured per frame, and
// windowDidEndLiveResize: covers the drop. The inLiveResize-false path catches
// the app's own resizes, from the View > Size presets and the pitch-panel
// toggle.
- (void)windowDidResize:(NSNotification *)notification {
    // Unlike the title refit, live-drag frames are not skipped: a wider
    // waveform is a faster playhead, and the re-arm is a no-op until the width
    // crosses a whole-Hz boundary.
    [self syncUITimerRate];
    // Re-evaluate the playing row against the window's live clip. Programmatic
    // collapse sets its final intent before the resize animation starts, but
    // the indicator remains visible for part of that travel.
    [self syncEqualizerActivity];
    if (!self.window.inLiveResize) {
        [self.trackDisplay refitTitleIfWidthChanged];
    }
}

- (void)windowDidEndLiveResize:(NSNotification *)notification {
    [self.trackDisplay refitTitleIfWidthChanged];
}

- (IBAction) toggleSize:(id)sender {
    MainWindow *window = (MainWindow *)self.window;
    [window toggleSize:sender];
}

+ (CGFloat)contentWidthForSizeIdentifier:(NSString *)identifier {
    switch (VibeWindowSizePresetForMenuIdentifier(identifier)) {
        case VibeWindowSizePresetSmall: return kMainWindowMinContentWidth;
        case VibeWindowSizePresetLarge: return kMainWindowLargeContentWidth;
        case VibeWindowSizePresetDefault: break;
    }
    return kMainWindowContentWidth;
}

- (IBAction) setWindowSize:(id)sender {
    if (![sender isKindOfClass:[NSMenuItem class]]) {
        return;
    }
    MainWindow *window = (MainWindow *)self.window;
    [window setContentWidth:[MainPlayerController contentWidthForSizeIdentifier:((NSMenuItem *)sender).identifier]
                    animate:YES];
}

// TRAP: shrinking the window does NOT hide the pitch panel. The panel is a
// contentView sibling anchored to the right edge (NSViewMinXMargin), so a
// resize slides it inward with the edge and it stays on screen at the new
// width — which is why togglePitchPanel: below pins both siblings for its
// animation and then re-asserts their frames. Nothing animates here, so the
// landing frames are the whole job: take them from the window's post-reset
// shown flags, which resetToDefaultShape has already cleared.
- (void)resetWindowToDefaultShape {
    [(MainWindow *)self.window resetToDefaultShape];
    self.playerContentView.frame = [self playerBodyFrame];
    _pitchPanel.frame = [self pitchPanelFrame];
}

- (IBAction) togglePitchPanel:(id)sender {
    MainWindow *window = (MainWindow *)self.window;
    BOOL show = !window.isPitchPanelShown;
    if (show) {
        // Sync the fader with the player before the reveal; it is cheap either
        // way.
        _pitchPanel.pitch = self.audioPlayer.pitch;
    }
    // The reveal, and its reverse, is the window's right edge sweeping past a
    // stationary panel, so both siblings are pinned in window coordinates for
    // the duration of the animation. The resizable-width masks would drag them
    // along with the edge instead: the body would shrink and re-grow, and the
    // panel would slide in from over the body rather than being uncovered.
    MainPlayerContentView *body = self.playerContentView;
    NSAutoresizingMaskOptions bodyMask = body.autoresizingMask;
    NSAutoresizingMaskOptions panelMask = _pitchPanel.autoresizingMask;
    body.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    _pitchPanel.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    [window setPitchPanelShown:show animate:YES];
    body.autoresizingMask = bodyMask;
    _pitchPanel.autoresizingMask = panelMask;
    // Re-assert the landing frames. A width clamped by the floor leaves the
    // frozen frames a few points off the finished window.
    body.frame = [self playerBodyFrame];
    _pitchPanel.frame = [self pitchPanelFrame];
}

- (IBAction) toggleAlwaysOnTop:(id)sender {
    AppSettings.sharedInstance.alwaysOnTop = !AppSettings.sharedInstance.alwaysOnTop;
    [self applySettingsLiveEffects:VibeSettingsLiveEffectAlwaysOnTop];
}

- (void)applyAlwaysOnTop {
    self.window.level = AppSettings.sharedInstance.alwaysOnTop ? NSFloatingWindowLevel : NSNormalWindowLevel;
    // About and Settings follow the player's level, or it would bury them.
    [(AppDelegate *)NSApp.delegate applyAuxiliaryWindowLevels];
}

- (IBAction)setAppearance:(id)sender {
    if (![sender isKindOfClass:NSMenuItem.class]) {
        return;
    }
    NSMenuItem *item = sender;
    if ([item.identifier isEqualToString:@"view_appearance_light"]) {
        AppSettings.sharedInstance.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT;
    }
    else if ([item.identifier isEqualToString:@"view_appearance_dark"]) {
        AppSettings.sharedInstance.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK;
    }
    else {
        AppSettings.sharedInstance.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT;
    }
    [self applySettingsLiveEffects:VibeSettingsLiveEffectWindowAppearance];
}

- (void)applyStoredAppearance {
    self.window.appearance = AppSettings.sharedInstance.windowAppearance;
    [self.playlistController reloadCurrentTrack];
}

+ (void)restoreWindowWithIdentifier:(NSString *)identifier
                              state:(NSCoder *)state
                  completionHandler:(void (^)(NSWindow *, NSError *))completionHandler {
    NSWindow *window = nil;
    if ([identifier isEqualToString:@"main_window"]) {
        AppDelegate *appDelegate = [NSApp delegate];
        window = appDelegate.mainPlayerController.window;
    }
    completionHandler(window, nil);
}

@end
