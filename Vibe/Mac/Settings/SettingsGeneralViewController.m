//
//  SettingsGeneralViewController.m
//  Vibe
//

#import "SettingsGeneralViewController.h"
#import "AppDelegate.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "DefaultAppRegistration.h"
#import "MainPlayerController+Settings.h"
#import "VibeStrings.h"

static const CGFloat kGeneralPopUpWidth = 280;

@implementation SettingsGeneralViewController {
    NSButton *_defaultPlayerButton;
    VibeSwitch *_alwaysOnTopSwitch;
    VibeSwitch *_lockWindowPositionSwitch;
    VibeSwitch *_reopenPlaylistSwitch;
    NSPopUpButton *_waveformDragPopUp;
    NSPopUpButton *_artworkDragPopUp;
#if VIBE_DIRECT_DISTRIBUTION
    NSPopUpButton *_updateCheckPopUp;
    VibeSwitch *_betaUpdatesSwitch;
#endif
    // Shown on refresh while the async check runs.
    BOOL _lastKnownIsDefaultPlayer;
    NSUInteger _defaultPlayerCheckGeneration;
}

- (void)loadView {
    // The pane is measured before the async default-app check answers, so
    // floor the button at the wider of its two titles or a long one clips.
    _defaultPlayerButton = [NSButton buttonWithTitle:[self defaultPlayerTitle:NO]
                                              target:self action:@selector(makeDefaultPlayer:)];
    CGFloat widestTitle = _defaultPlayerButton.fittingSize.width;
    _defaultPlayerButton.title = [self defaultPlayerTitle:YES];
    widestTitle = MAX(widestTitle, _defaultPlayerButton.fittingSize.width);
    [_defaultPlayerButton.widthAnchor constraintGreaterThanOrEqualToConstant:widestTitle].active = YES;

    _alwaysOnTopSwitch = [self switchWithAction:@selector(toggleAlwaysOnTop:)];
    _lockWindowPositionSwitch = [self switchWithAction:@selector(toggleLockWindowPosition:)];
    _reopenPlaylistSwitch = [self switchWithAction:@selector(toggleReopenPlaylist:)];

    // No live effect: each view reads its setting per gesture.
    _waveformDragPopUp = [self popUpButtonWithWidth:kGeneralPopUpWidth action:@selector(waveformDragChanged:)];
    [self addItem:STR_SETTINGS_WAVEFORM_DRAG_WINDOW value:SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW to:_waveformDragPopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_DRAG_SEEK value:SETTINGS_VALUE_WAVEFORM_DRAG_SEEK to:_waveformDragPopUp];

    _artworkDragPopUp = [self popUpButtonWithWidth:kGeneralPopUpWidth action:@selector(artworkDragChanged:)];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_FILE value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE to:_artworkDragPopUp];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_PATH value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_PATH to:_artworkDragPopUp];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_NAME value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_ARTIST_TITLE to:_artworkDragPopUp];

#if VIBE_DIRECT_DISTRIBUTION
    // Seconds, as AppDelegate.updateCheckInterval takes them; 0 is never.
    _updateCheckPopUp = [self popUpButtonWithWidth:kGeneralPopUpWidth action:@selector(updateCheckChanged:)];
    [self addItem:STR_SETTINGS_UPDATE_CHECK_NEVER value:@0 to:_updateCheckPopUp];
    NSArray<NSString *> *intervalTitles = @[STR_SETTINGS_UPDATE_CHECK_DAILY, STR_SETTINGS_UPDATE_CHECK_WEEKLY,
                                            STR_SETTINGS_UPDATE_CHECK_MONTHLY];
    NSAssert(intervalTitles.count == kVibeUpdateCheckIntervalPresetCount,
             @"Every update check interval needs a title");
    for (size_t i = 0; i < kVibeUpdateCheckIntervalPresetCount; i++) {
        [self addItem:intervalTitles[i] value:@(kVibeUpdateCheckIntervalPresets[i]) to:_updateCheckPopUp];
    }
    _betaUpdatesSwitch = [self switchWithAction:@selector(betaUpdatesChanged:)];
#endif

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_BEHAVIOR_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_REOPEN_PLAYLIST
                                  caption:STR_SETTINGS_REOPEN_PLAYLIST_CAPTION
                                  control:_reopenPlaylistSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_DRAG_LABEL control:_waveformDragPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_ARTWORK_DRAG_LABEL control:_artworkDragPopUp],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_ALWAYS_ON_TOP control:_alwaysOnTopSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_LOCK_WINDOW_POSITION
                                  caption:STR_SETTINGS_LOCK_WINDOW_POSITION_CAPTION control:_lockWindowPositionSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_SYSTEM_SECTION rows:@[
#if VIBE_DIRECT_DISTRIBUTION
            [SettingsRowView rowWithTitle:STR_SETTINGS_UPDATE_CHECK_LABEL control:_updateCheckPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_BETA_UPDATES_LABEL
                                  caption:STR_SETTINGS_BETA_UPDATES_CAPTION control:_betaUpdatesSwitch],
#endif
            [SettingsRowView rowWithTitle:STR_SETTINGS_DEFAULT_PLAYER_LABEL control:_defaultPlayerButton],
        ]],
    ]];
}

- (void)refreshFromSettings {
    [self refreshDefaultPlayerButton];
    _alwaysOnTopSwitch.state = AppSettings.sharedInstance.alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    _lockWindowPositionSwitch.state = AppSettings.sharedInstance.windowPositionLocked ? NSControlStateValueOn : NSControlStateValueOff;
    _reopenPlaylistSwitch.state = AppSettings.sharedInstance.reopenLastPlaylist ? NSControlStateValueOn : NSControlStateValueOff;
    [self selectValue:AppSettings.sharedInstance.waveformDragBehavior in:_waveformDragPopUp];
    [self selectValue:AppSettings.sharedInstance.artworkDragAction in:_artworkDragPopUp];
#if VIBE_DIRECT_DISTRIBUTION
    [self selectValue:@([(AppDelegate *)NSApp.delegate updateCheckInterval]) in:_updateCheckPopUp];
    _betaUpdatesSwitch.state = AppSettings.sharedInstance.receiveBetaUpdates ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshBetaUpdatesEnabled];
#endif
}

- (void)toggleAlwaysOnTop:(id)sender {
    AppSettings.sharedInstance.alwaysOnTop = (_alwaysOnTopSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectAlwaysOnTop];
}

- (void)toggleLockWindowPosition:(id)sender {
    AppSettings.sharedInstance.windowPositionLocked = (_lockWindowPositionSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWindowLock];
}

- (void)toggleReopenPlaylist:(id)sender {
    AppSettings.sharedInstance.reopenLastPlaylist = (_reopenPlaylistSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectReopenLastPlaylist];
}

- (void)waveformDragChanged:(id)sender {
    AppSettings.sharedInstance.waveformDragBehavior = _waveformDragPopUp.selectedItem.representedObject;
}

- (void)artworkDragChanged:(id)sender {
    AppSettings.sharedInstance.artworkDragAction = _artworkDragPopUp.selectedItem.representedObject;
}

#if VIBE_DIRECT_DISTRIBUTION
- (void)updateCheckChanged:(id)sender {
    [(AppDelegate *)NSApp.delegate setUpdateCheckInterval:[_updateCheckPopUp.selectedItem.representedObject doubleValue]];
    [self refreshBetaUpdatesEnabled];
}

// Never disables the row but keeps its value: Check for Updates… still
// honors it.
- (void)refreshBetaUpdatesEnabled {
    [SettingsRowView setControl:_betaUpdatesSwitch
                        enabled:[(AppDelegate *)NSApp.delegate updateCheckInterval] > 0];
}

- (void)betaUpdatesChanged:(id)sender {
    AppSettings.sharedInstance.receiveBetaUpdates = _betaUpdatesSwitch.state == NSControlStateValueOn;
}
#endif

#pragma mark - Default music player

// The system's panels ask about each type. When it refused them all without
// asking, as it can a sandboxed app, the Finder is the way left.
- (void)makeDefaultPlayer:(id)sender {
    __weak __typeof(self) weakSelf = self;
    [DefaultAppRegistration makeDefaultAppWithCompletion:^(BOOL refused) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf refreshDefaultPlayerButton];
        if (refused && strongSelf.view.window) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = [NSString stringWithFormat:STR_SETTINGS_DEFAULT_PLAYER_REFUSED_TITLE, VibeAppName()];
            alert.informativeText = [NSString stringWithFormat:STR_SETTINGS_DEFAULT_PLAYER_REFUSED_MESSAGE, VibeAppName()];
            [alert beginSheetModalForWindow:strongSelf.view.window completionHandler:nil];
        }
    }];
}

- (void)refreshDefaultPlayerButton {
    [self renderDefaultPlayerState:_lastKnownIsDefaultPlayer];
    NSUInteger generation = ++_defaultPlayerCheckGeneration;
    __weak __typeof(self) weakSelf = self;
    [DefaultAppRegistration checkIsDefaultAppForAllFileTypes:^(BOOL isDefault) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_defaultPlayerCheckGeneration) {
            return;
        }
        strongSelf->_lastKnownIsDefaultPlayer = isDefault;
        [strongSelf renderDefaultPlayerState:isDefault];
    }];
}

- (NSString *)defaultPlayerTitle:(BOOL)isDefault {
    return [NSString stringWithFormat:
            isDefault ? STR_SETTINGS_DEFAULT_PLAYER_IS : STR_SETTINGS_DEFAULT_PLAYER_SET, VibeAppName()];
}

- (void)renderDefaultPlayerState:(BOOL)isDefault {
    _defaultPlayerButton.title = [self defaultPlayerTitle:isDefault];
    [SettingsRowView setControl:_defaultPlayerButton enabled:!isDefault];
}

@end
