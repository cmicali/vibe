//
//  SettingsGeneralViewController.m
//  Vibe
//

#import "SettingsGeneralViewController.h"
#import "AppSettings.h"
#import "AudioDeviceManager.h"
#import "AudioPlayer.h"
#import "DefaultAppRegistration.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Window.h"
#import "OutputDevicesMenuController.h"
#import "VibeStrings.h"

static const CGFloat kOutputPopUpWidth = 280;

@interface SettingsGeneralViewController () <AudioDeviceManagerObserver>
@end

@implementation SettingsGeneralViewController {
    // Owns the popup menu's layout and the change action — the same class
    // that serves the menu bar's Output menu, so the two cannot drift. Its
    // own device observation refreshes the popup while it is open; the
    // observation below covers it while it is closed.
    OutputDevicesMenuController *_outputMenuController;
    NSPopUpButton *_outputPopUp;
    NSButton *_defaultPlayerButton;
    NSSwitch *_alwaysOnTopSwitch;
    NSPopUpButton *_waveformDragPopUp;
    // The last answer from the async default-app check, shown immediately on
    // refresh while the fresh one is fetched; the generation drops a stale
    // reply that lands after a newer refresh.
    BOOL _lastKnownIsDefaultPlayer;
    NSUInteger _defaultPlayerCheckGeneration;
}

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController {
    self = [super initWithPlayerController:playerController];
    if (self) {
        _outputMenuController = [[OutputDevicesMenuController alloc] init];
        _outputMenuController.audioPlayer = playerController.audioPlayer;
        [AudioDeviceManager.sharedInstance addObserver:self];
    }
    return self;
}

- (void)loadView {
    _outputPopUp = [self popUpButtonWithWidth:kOutputPopUpWidth action:NULL];
    _outputPopUp.menu.delegate = _outputMenuController;

    // The pane is measured once, here, while the async default-app check is
    // still out and the real title has not arrived. Floor the button at the
    // wider of the two titles it can carry, or the pane's width freezes
    // against an empty one and a locale whose title outgrows the design width
    // gets a clipped button — this pane's widest control.
    _defaultPlayerButton = [NSButton buttonWithTitle:[self defaultPlayerTitle:NO]
                                              target:self action:@selector(makeDefaultPlayer:)];
    CGFloat widestTitle = _defaultPlayerButton.fittingSize.width;
    _defaultPlayerButton.title = [self defaultPlayerTitle:YES];
    widestTitle = MAX(widestTitle, _defaultPlayerButton.fittingSize.width);
    [_defaultPlayerButton.widthAnchor constraintGreaterThanOrEqualToConstant:widestTitle].active = YES;

    _alwaysOnTopSwitch = [self switchWithAction:@selector(toggleAlwaysOnTop:)];

    // Identifiers in representedObject, localized names in the titles — a
    // display name must never reach NSUserDefaults. No live-apply hook: the
    // waveform view reads the setting per mouse-down.
    _waveformDragPopUp = [self popUpButtonWithWidth:kOutputPopUpWidth action:@selector(waveformDragChanged:)];
    [_waveformDragPopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_DRAG_WINDOW];
    _waveformDragPopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW;
    [_waveformDragPopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_DRAG_SEEK];
    _waveformDragPopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_DRAG_SEEK;

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_AUDIO_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_OUTPUT_LABEL control:_outputPopUp],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_ALWAYS_ON_TOP control:_alwaysOnTopSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_DRAG_LABEL control:_waveformDragPopUp],
        ]],
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:nil control:_defaultPlayerButton],
        ]],
    ]];
}

- (void)refreshFromSettings {
    [self refreshOutputPopUp];
    [self refreshDefaultPlayerButton];
    _alwaysOnTopSwitch.state = AppSettings.sharedInstance.alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    // The getter is normalized, so a match always exists.
    NSString *dragBehavior = AppSettings.sharedInstance.waveformDragBehavior;
    for (NSMenuItem *item in _waveformDragPopUp.itemArray) {
        if ([item.representedObject isEqualToString:dragBehavior]) {
            [_waveformDragPopUp selectItem:item];
            break;
        }
    }
}

- (void)toggleAlwaysOnTop:(id)sender {
    AppSettings.sharedInstance.alwaysOnTop = (_alwaysOnTopSwitch.state == NSControlStateValueOn);
    [self.playerController applyAlwaysOnTop];
}

- (void)waveformDragChanged:(id)sender {
    AppSettings.sharedInstance.waveformDragBehavior = _waveformDragPopUp.selectedItem.representedObject;
}

#pragma mark - Output device

// Same layout and checkmark rule as the menu bar's Output menu, built by the
// same controller; the popup's selection then follows the checked item. The
// controller-set item state and the popup's own selected-item checkmark are
// deliberately redundant — they land on the same item as long as this
// selection stays in sync, so neither path should be removed.
- (void)refreshOutputPopUp {
    [_outputMenuController menuNeedsUpdate:_outputPopUp.menu];
    AudioPlayer *audioPlayer = self.playerController.audioPlayer;
    NSInteger requestedId = audioPlayer ? audioPlayer.currentlyRequestedAudioDeviceId : -1;
    if (![_outputPopUp selectItemWithTag:requestedId]) {
        // A chosen device that vanished: the player falls back to System
        // Output, so show that.
        [_outputPopUp selectItemWithTag:-1];
    }
}

- (void)audioOutputDevicesDidChange {
    if (self.viewLoaded) {
        [self refreshOutputPopUp];
    }
}

- (void)systemDefaultOutputDeviceDidChange {
    if (self.viewLoaded) {
        [self refreshOutputPopUp];
    }
}

#pragma mark - Default music player

- (void)makeDefaultPlayer:(id)sender {
    // The system runs its own confirmation panel and reports the outcome
    // itself; the button retitles on the base class's key-window refresh.
    [DefaultAppRegistration makeDefaultApp];
}

// The check walks Launch Services off the main thread, so show the last-known
// state now and correct it when the fresh answer lands.
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

// Nothing to do once Vibe already holds every type, so the title says so and
// the button disables rather than offering a no-op.
- (NSString *)defaultPlayerTitle:(BOOL)isDefault {
    return [NSString stringWithFormat:
            isDefault ? STR_SETTINGS_DEFAULT_PLAYER_IS : STR_SETTINGS_DEFAULT_PLAYER_SET, VibeAppName()];
}

- (void)renderDefaultPlayerState:(BOOL)isDefault {
    _defaultPlayerButton.title = [self defaultPlayerTitle:isDefault];
    _defaultPlayerButton.enabled = !isDefault;
}

@end
