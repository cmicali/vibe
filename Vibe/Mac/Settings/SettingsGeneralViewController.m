//
//  SettingsGeneralViewController.m
//  Vibe
//

#import "SettingsGeneralViewController.h"
#import "AppDelegate.h"
#if VIBE_DIRECT_DISTRIBUTION
#import "VibeUpdater.h"
#endif
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "DefaultAppRegistration.h"
#import "MainPlayerController+Settings.h"
#import "NSImage+Util.h"
#import "VibeStrings.h"

static const CGFloat kGeneralPopUpWidth = 280;

@implementation SettingsGeneralViewController {
    // One of the two shows: the button until the app holds every type, then
    // the checkmarked label. A done state drawn as a disabled button read as
    // unavailable.
    NSButton *_defaultPlayerButton;
    NSStackView *_defaultPlayerDoneCluster;
    VibeSwitch *_alwaysOnTopSwitch;
    VibeSwitch *_lockWindowPositionSwitch;
    VibeSwitch *_reopenPlaylistSwitch;
    NSPopUpButton *_waveformDragPopUp;
    NSPopUpButton *_artworkDragPopUp;
#if VIBE_DIRECT_DISTRIBUTION
    VibeSwitch *_updateCheckSwitch;
    NSButton *_checkNowButton;
    VibeSwitch *_betaUpdatesSwitch;
#endif
    // Shown on refresh while the async check runs.
    BOOL _lastKnownIsDefaultPlayer;
    NSUInteger _defaultPlayerCheckGeneration;
}

- (void)loadView {
    _defaultPlayerButton = [NSButton buttonWithTitle:[NSString stringWithFormat:STR_SETTINGS_DEFAULT_PLAYER_SET,
                                                      VibeAppName()]
                                              target:self action:@selector(makeDefaultPlayer:)];
    NSImageView *check = [NSImageView imageViewWithImage:[NSImage symbolNamed:@"checkmark.circle.fill"
            pointSize:NSFont.systemFontSize weight:NSFontWeightRegular
              palette:@[NSColor.whiteColor, NSColor.systemGreenColor]
            accessibilityDescription:nil]];
    NSTextField *doneLabel = [NSTextField labelWithString:[NSString stringWithFormat:STR_SETTINGS_DEFAULT_PLAYER_IS,
                                                           VibeAppName()]];
    doneLabel.textColor = NSColor.secondaryLabelColor;
    _defaultPlayerDoneCluster = [NSStackView stackViewWithViews:@[check, doneLabel]];
    _defaultPlayerDoneCluster.spacing = 4;
    _defaultPlayerDoneCluster.hidden = YES;

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

    NSMutableArray<SettingsSectionView *> *sections = [@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_BEHAVIOR_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_REOPEN_PLAYLIST control:_reopenPlaylistSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_DRAG_LABEL control:_waveformDragPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_ARTWORK_DRAG_LABEL control:_artworkDragPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_DEFAULT_PLAYER_LABEL
                                 controls:@[_defaultPlayerDoneCluster, _defaultPlayerButton]],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_PLACEMENT_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_ALWAYS_ON_TOP control:_alwaysOnTopSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_LOCK_WINDOW_POSITION control:_lockWindowPositionSwitch],
        ]],
    ] mutableCopy];
#if VIBE_DIRECT_DISTRIBUTION
    _updateCheckSwitch = [self switchWithAction:@selector(updateCheckChanged:)];
    // The controller exists before any window and never changes. Unstarted
    // (a Debug build without --update-feed) it refuses the check and logs.
    _checkNowButton = [NSButton buttonWithTitle:STR_SETTINGS_UPDATE_CHECK_NOW_BUTTON
                                         target:[(AppDelegate *)NSApp.delegate updater].controller
                                         action:@selector(checkForUpdates:)];
    _betaUpdatesSwitch = [self switchWithAction:@selector(betaUpdatesChanged:)];
    [sections addObject:[SettingsSectionView sectionWithHeader:STR_SETTINGS_UPDATES_SECTION rows:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_UPDATE_CHECK_LABEL control:_updateCheckSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_UPDATE_CHECK_NOW_LABEL control:_checkNowButton],
        [SettingsRowView rowWithTitle:STR_SETTINGS_BETA_UPDATES_LABEL control:_betaUpdatesSwitch],
    ]]];
#endif
    [self loadPaneWithSections:sections];
}

- (void)refreshFromSettings {
    [self refreshDefaultPlayerButton];
    _alwaysOnTopSwitch.state = AppSettings.sharedInstance.alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    _lockWindowPositionSwitch.state = AppSettings.sharedInstance.windowPositionLocked ? NSControlStateValueOn : NSControlStateValueOff;
    _reopenPlaylistSwitch.state = AppSettings.sharedInstance.reopenLastPlaylist ? NSControlStateValueOn : NSControlStateValueOff;
    [self selectValue:AppSettings.sharedInstance.waveformDragBehavior in:_waveformDragPopUp];
    [self selectValue:AppSettings.sharedInstance.artworkDragAction in:_artworkDragPopUp];
#if VIBE_DIRECT_DISTRIBUTION
    _updateCheckSwitch.state = StateForBOOL([(AppDelegate *)NSApp.delegate updater].checkInterval > 0);
    // Never disabled with the automatic check off: Check Now still honors it.
    _betaUpdatesSwitch.state = StateForBOOL(AppSettings.sharedInstance.receiveBetaUpdates);
#endif
}

- (void)toggleAlwaysOnTop:(id)sender {
    AppSettings.sharedInstance.alwaysOnTop = (_alwaysOnTopSwitch.state == NSControlStateValueOn);
    [self applyLiveEffects:VibeSettingsLiveEffectAlwaysOnTop];
}

- (void)toggleLockWindowPosition:(id)sender {
    AppSettings.sharedInstance.windowPositionLocked = (_lockWindowPositionSwitch.state == NSControlStateValueOn);
    [self applyLiveEffects:VibeSettingsLiveEffectWindowLock];
}

- (void)toggleReopenPlaylist:(id)sender {
    AppSettings.sharedInstance.reopenLastPlaylist = (_reopenPlaylistSwitch.state == NSControlStateValueOn);
    [self applyLiveEffects:VibeSettingsLiveEffectReopenLastPlaylist];
}

- (void)waveformDragChanged:(id)sender {
    AppSettings.sharedInstance.waveformDragBehavior = _waveformDragPopUp.selectedItem.representedObject;
    [self applyLiveEffects:VibeSettingsLiveEffectWaveformDrag];
}

- (void)artworkDragChanged:(id)sender {
    AppSettings.sharedInstance.artworkDragAction = _artworkDragPopUp.selectedItem.representedObject;
}

#if VIBE_DIRECT_DISTRIBUTION
// On is daily; off is never. A longer interval Sparkle still holds from an
// older build reads as on and is kept.
- (void)updateCheckChanged:(id)sender {
    VibeUpdater *updater = [(AppDelegate *)NSApp.delegate updater];
    BOOL on = _updateCheckSwitch.state == NSControlStateValueOn;
    if (on && updater.checkInterval <= 0) {
        updater.checkInterval = kVibeUpdateCheckIntervalDefault;
    } else if (!on) {
        updater.checkInterval = 0;
    }
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

// The swap lands after the async check, outside the refresh that measures
// the pane, so it remeasures itself.
- (void)renderDefaultPlayerState:(BOOL)isDefault {
    if (_defaultPlayerButton.hidden == isDefault) {
        return;
    }
    _defaultPlayerButton.hidden = isDefault;
    _defaultPlayerDoneCluster.hidden = !isDefault;
    [self paneContentDidChange];
}

@end
