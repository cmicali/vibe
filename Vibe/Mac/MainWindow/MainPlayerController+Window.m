//
//  MainPlayerController+Window.m
//  Vibe
//

#import "MainPlayerController+Window.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Settings.h"

#import "AppDelegate.h"
#import "AppSettings.h"
#import "ArtworkDisplayController.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "MainMenuBuilder.h" // vends the context-menu items shared with the main menu
#import "MainPlayerContentView.h"
#import "MainWindow.h"
#import "MenuValidationRules.h"
#import "NSDockTile+Util.h"
#import "PitchControlPanel.h"
#import "PlaylistController.h"
#import "PlaylistTableView.h"
#import "NSView+DarkMode.h"
#import "SymbolButton.h"
#import "TrackDisplayController.h"
#import "UIUpdateTimer.h"
#import "VibeStrings.h"

@implementation MainPlayerController (Window)

#pragma mark - Construction

- (void)buildContentInWindow:(MainWindow *)window {
    NSView *contentView = window.contentView;
    // Spans the whole window, pitch panel included. Before macOS 26 a frosted
    // blur stands in, shaped by maskImage: its blur ignores a layer radius.
    NSView *backdrop;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:contentView.bounds];
        glass.style = NSGlassEffectViewStyleClear;
        backdrop = glass;
    }
    else {
        NSVisualEffectView *frost = [[NSVisualEffectView alloc] initWithFrame:contentView.bounds];
        frost.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        frost.state = NSVisualEffectStateActive; // key-state-independent, like the playlist frost
        frost.material = NSVisualEffectMaterialUnderWindowBackground;
        backdrop = frost;
    }
    [MainPlayerContentView applyCornerRadius:AppSettings.sharedInstance.currentTheme.resolvedWindowCornerRadius
                                  toBackdrop:backdrop];
    backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [contentView addSubview:backdrop];
    self.windowBackdropView = backdrop;

    // The themed solid background, hidden under the default glass style.
    NSView *backgroundOverlay = [[NSView alloc] initWithFrame:contentView.bounds];
    backgroundOverlay.wantsLayer = YES;
    backgroundOverlay.layer.masksToBounds = YES;
    backgroundOverlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    backgroundOverlay.hidden = YES;
    [contentView addSubview:backgroundOverlay];
    self.windowBackgroundOverlayView = backgroundOverlay;
    [self applyWindowBackground];

    // The themed fonts must be in Fonts before any label is built.
    [self applyStoredFonts];
    MainPlayerContentView *content = [[MainPlayerContentView alloc] initWithTarget:self];
    self.playerContentView = content;
    [self applyTrafficLights];
    [contentView addSubview:content];
    // Stretches the design-size frames to the restored window.
    content.frame = [self playerBodyFrame];

    self.playButton = content.playButton;
    self.nextButton = content.nextButton;
    self.waveformView = content.waveformView;
    self.playlistTableView = content.playlistTableView;

    self.trackDisplay = [[TrackDisplayController alloc] initWithContentView:content];

    // A recognizer keeps the label a plain text field.
    NSClickGestureRecognizer *timeModeClick =
            [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(toggleTimeDisplayMode:)];
    [content.totalTimeTextField addGestureRecognizer:timeModeClick];

    // On the content view, so it covers the pitch panel too; the playlist
    // table's row menu shadows it. The vended items share the main menu's
    // validation. The title is never drawn.
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:VibeNotLocalized(@"Popup Menu")];
    [contextMenu addItem:[MainMenuBuilder symbolItemWithTitle:STR_MENU_SHOW_IN_FINDER
                                                   symbolName:@"folder"
                                                       action:@selector(showInFinder:)
                                                       target:self
                                                   identifier:kVibeMenuShowInFinder]];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    [contextMenu addItem:[MainMenuBuilder copyNameItemWithTarget:self]];
    [contextMenu addItem:[MainMenuBuilder copyFileItemWithTarget:self]];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    [contextMenu addItem:[MainMenuBuilder convertToFLACItemWithTarget:self]];
    contentView.menu = contextMenu;
}

// The masks keep both frames through a drag; these compute them outright.
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

// A contentView sibling of the body, revealed by widening the window.
// Right-anchored, so a drag keeps it on the edge, or parked past it.
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

// Drags only: an animated resize's intermediate frames must not be snapped.
- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize {
    if (sender.inLiveResize) {
        frameSize.height = [(MainWindow *)sender restingHeightForDraggedHeight:frameSize.height];
    }
    return frameSize;
}

// The title refit skips live-drag frames; windowDidEndLiveResize: covers the
// drop.
- (void)windowDidResize:(NSNotification *)notification {
    // Every frame: a wider waveform is a faster playhead.
    [self syncUITimerRate];
    // A programmatic collapse sets its final intent before the animation, but
    // the playing row stays visible for part of the travel.
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

// TRAP: shrinking the window does NOT hide the pitch panel: its right-anchored
// mask rides the edge inward. So the frames are re-asserted from the window's
// post-reset shown flags.
- (void)resetWindowToDefaultShape {
    [(MainWindow *)self.window resetToDefaultShape];
    self.playerContentView.frame = [self playerBodyFrame];
    _pitchPanel.frame = [self pitchPanelFrame];
}

- (IBAction) togglePitchPanel:(id)sender {
    MainWindow *window = (MainWindow *)self.window;
    BOOL show = !window.isPitchPanelShown;
    if (show) {
        if (!AppSettings.sharedInstance.pitchControlAllowed) {
            return; // the one gate: the menu item, the P key and the debug verb all land here
        }
        _pitchPanel.pitch = self.audioPlayer.pitch;
    }
    // Both siblings are pinned for the animation: the resizable masks would
    // shrink the body and slide the panel in over it, not uncover it.
    MainPlayerContentView *body = self.playerContentView;
    NSAutoresizingMaskOptions bodyMask = body.autoresizingMask;
    NSAutoresizingMaskOptions panelMask = _pitchPanel.autoresizingMask;
    body.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    _pitchPanel.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    [window setPitchPanelShown:show animate:YES];
    body.autoresizingMask = bodyMask;
    _pitchPanel.autoresizingMask = panelMask;
    // A width clamped by the floor leaves the pinned frames a few points off.
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

- (IBAction)toggleWindowPositionLock:(id)sender {
    AppSettings.sharedInstance.windowPositionLocked = !AppSettings.sharedInstance.windowPositionLocked;
    [self applySettingsLiveEffects:VibeSettingsLiveEffectWindowLock];
}

- (void)applyWindowLock {
    self.window.movable = !AppSettings.sharedInstance.windowPositionLocked;
}

- (void)applyTrafficLights {
    [self.playerContentView setTrafficLightsShown:AppSettings.sharedInstance.showTrafficLights];
}

// The icon first: the tile reads it live.
- (void)applyAppIcon {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    [NSDockTile setAppIcon:[theme customImageForKey:kVibeThemeImageAppIcon] shaped:theme.appIconShape];
    [self->_artworkController applyDockIcon];
}

- (void)applyWindowChrome {
    CGFloat radius = AppSettings.sharedInstance.currentTheme.resolvedWindowCornerRadius;
    NSView *contentView = self.window.contentView;
    contentView.layer.cornerRadius = radius;
    [MainPlayerContentView applyCornerRadius:radius toBackdrop:self.windowBackdropView];
    [self applyWindowBackground];
    self->_pitchPanel.needsDisplay = YES;
    [self.window invalidateShadow];
}

- (void)applyWindowBackground {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    NSView *overlay = self.windowBackgroundOverlayView;
    // From the WINDOW: mid-flip a view can still report the outgoing
    // appearance (APPEARANCE.md's refreshTintWashes trap).
    BOOL dark = self.window.effectiveAppearance.isDark;
    // An unset pair (a hand-edited import) draws the accessor's default.
    NSColor *color = [theme.windowBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID]
            ? [theme displayColorForBase:kVibeThemeColorWindowBackground dark:dark] : nil;
    overlay.hidden = (color == nil);
    overlay.layer.backgroundColor = color.CGColor;
    overlay.layer.cornerRadius = theme.resolvedWindowCornerRadius;
    // nil before the body is built, which applies its own.
    [self.playerContentView applyWindowBackgroundStyle];
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
