//
//  SettingsGeneralViewController.m
//  Vibe
//

#import "SettingsGeneralViewController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioDeviceManager.h"
#import "AudioPlayer.h"
#import "DefaultAppRegistration.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Transport.h"
#import "OutputDevicesMenuController.h"
#import "OutputFormatRules.h"
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
    // Enabled only for a device bit-perfect output can drive; the row's
    // caption says why otherwise, and names the format while it is active.
    NSSwitch *_bitPerfectSwitch;
    SettingsRowView *_bitPerfectRow;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    NSSwitch *_exclusiveOutputSwitch;
    SettingsRowView *_exclusiveOutputRow;
#endif
    NSButton *_defaultPlayerButton;
    NSSwitch *_alwaysOnTopSwitch;
    NSSwitch *_reopenPlaylistSwitch;
    NSPopUpButton *_waveformDragPopUp;
    NSPopUpButton *_artworkDragPopUp;
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

    _bitPerfectSwitch = [self switchWithAction:@selector(toggleBitPerfect:)];
    _bitPerfectRow = [SettingsRowView rowWithTitle:STR_SETTINGS_BIT_PERFECT
                                           caption:STR_SETTINGS_BIT_PERFECT_CAPTION_OFF
                                           control:_bitPerfectSwitch];
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    _exclusiveOutputSwitch = [self switchWithAction:@selector(toggleExclusiveOutput:)];
    _exclusiveOutputRow = [SettingsRowView rowWithTitle:STR_SETTINGS_EXCLUSIVE_OUTPUT
                                               caption:STR_SETTINGS_EXCLUSIVE_OUTPUT_CAPTION
                                               control:_exclusiveOutputSwitch];
#endif

    _alwaysOnTopSwitch = [self switchWithAction:@selector(toggleAlwaysOnTop:)];
    _reopenPlaylistSwitch = [self switchWithAction:@selector(toggleReopenPlaylist:)];

    // Identifiers in representedObject, localized names in the titles — a
    // display name must never reach NSUserDefaults. No live effect for
    // either popup: the waveform view reads its setting per mouse-down, the
    // art view reads its own per drag start.
    _waveformDragPopUp = [self popUpButtonWithWidth:kOutputPopUpWidth action:@selector(waveformDragChanged:)];
    [self addItem:STR_SETTINGS_WAVEFORM_DRAG_WINDOW value:SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW to:_waveformDragPopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_DRAG_SEEK value:SETTINGS_VALUE_WAVEFORM_DRAG_SEEK to:_waveformDragPopUp];

    _artworkDragPopUp = [self popUpButtonWithWidth:kOutputPopUpWidth action:@selector(artworkDragChanged:)];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_FILE value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE to:_artworkDragPopUp];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_PATH value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_PATH to:_artworkDragPopUp];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_NAME value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_ARTIST_TITLE to:_artworkDragPopUp];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_AUDIO_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_OUTPUT_LABEL control:_outputPopUp],
            _bitPerfectRow,
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
            _exclusiveOutputRow,
#endif
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_STARTUP_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_REOPEN_PLAYLIST
                                  caption:STR_SETTINGS_REOPEN_PLAYLIST_CAPTION
                                  control:_reopenPlaylistSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_ALWAYS_ON_TOP control:_alwaysOnTopSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_DRAG_LABEL control:_waveformDragPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_ARTWORK_DRAG_LABEL control:_artworkDragPopUp],
        ]],
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_DEFAULT_PLAYER_LABEL control:_defaultPlayerButton],
        ]],
    ]];
}

- (void)refreshFromSettings {
    [self refreshOutputPopUp];
    [self refreshBitPerfectRows];
    [self refreshDefaultPlayerButton];
    _alwaysOnTopSwitch.state = AppSettings.sharedInstance.alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    _reopenPlaylistSwitch.state = AppSettings.sharedInstance.reopenLastPlaylist ? NSControlStateValueOn : NSControlStateValueOff;
    // The getters are normalized, so a match always exists.
    [self selectValue:AppSettings.sharedInstance.waveformDragBehavior in:_waveformDragPopUp];
    [self selectValue:AppSettings.sharedInstance.artworkDragAction in:_artworkDragPopUp];
}

// The switch follows the Output popup beside it: enabled only while the
// chosen device is one the mode can drive (OutputFormatRules.h), with the
// caption saying why otherwise. On, the caption is the player's own report —
// the same sentence the header's open lock shows on hover — and the report
// settles asynchronously, so the toggle's own call shows the previous one
// until the player controller's report-change call corrects it.
- (void)refreshBitPerfectRows {
    if (!self.viewLoaded) {
        return;
    }
    AudioPlayer *audioPlayer = self.playerController.audioPlayer;
    NSInteger requestedId = audioPlayer ? audioPlayer.currentlyRequestedAudioDeviceId : -1;
    AudioDevice *device = [AudioDeviceManager.sharedInstance outputDeviceForId:requestedId];
    BOOL eligible = device && VibeBitPerfectDeviceEligible(device.transportType);
    BOOL on = AppSettings.sharedInstance.bitPerfectOutput;
    _bitPerfectSwitch.enabled = on || eligible; // an unavailable saved device must not trap the mode on
    _bitPerfectSwitch.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *caption;
    if (!eligible) {
        caption = STR_SETTINGS_BIT_PERFECT_NEEDS_DEVICE;
    }
    else if (on) {
        caption = [self.playerController bitPerfectStatusText];
    }
    else {
        caption = STR_SETTINGS_BIT_PERFECT_CAPTION_OFF;
    }
    BOOL captionChanged = [_bitPerfectRow setCaption:caption];
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    BOOL exclusiveEligible = device && VibeBitPerfectShouldHog(YES, device.transportType,
            device.isSystemDefault);
    _exclusiveOutputSwitch.enabled = on && exclusiveEligible;
    _exclusiveOutputSwitch.state = AppSettings.sharedInstance.exclusiveOutput
            ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *exclusiveCaption = !on ? STR_SETTINGS_EXCLUSIVE_OUTPUT_NEEDS_BIT_PERFECT
            : !exclusiveEligible ? STR_SETTINGS_EXCLUSIVE_OUTPUT_NEEDS_DEVICE
            : STR_SETTINGS_EXCLUSIVE_OUTPUT_CAPTION;
    captionChanged |= [_exclusiveOutputRow setCaption:exclusiveCaption];
#endif
    if (captionChanged) {
        [self paneContentDidChange];
    }
}

- (void)toggleBitPerfect:(id)sender {
    AppSettings.sharedInstance.bitPerfectOutput = (_bitPerfectSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfectApply];
    [self refreshBitPerfectRows];
    [self refreshOutputPopUp]; // the popup grays ineligible devices out while on
}

#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
- (void)toggleExclusiveOutput:(id)sender {
    AppSettings.sharedInstance.exclusiveOutput = (_exclusiveOutputSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfect];
    [self refreshBitPerfectRows];
}
#endif

- (void)toggleAlwaysOnTop:(id)sender {
    AppSettings.sharedInstance.alwaysOnTop = (_alwaysOnTopSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectAlwaysOnTop];
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
        [self refreshBitPerfectRows];
    }
}

- (void)systemDefaultOutputDeviceDidChange {
    if (self.viewLoaded) {
        [self refreshOutputPopUp];
        [self refreshBitPerfectRows];
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
