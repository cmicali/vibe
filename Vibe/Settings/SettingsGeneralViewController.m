//
//  SettingsGeneralViewController.m
//  Vibe
//

#import "SettingsGeneralViewController.h"
#import "AudioDeviceManager.h"
#import "AudioPlayer.h"
#import "DefaultAppClaim.h"
#import "MainPlayerController.h"
#import "OutputDevicesMenuController.h"
#import "VibeStrings.h"

static const CGFloat kGeneralPaneHeight = 180;
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

    _defaultPlayerButton = [NSButton buttonWithTitle:@"" target:self action:@selector(makeDefaultPlayer:)];

    NSGridView *grid = [self.class formGridWithRows:@[
        @[[NSTextField labelWithString:STR_SETTINGS_OUTPUT_LABEL], _outputPopUp],
        @[NSGridCell.emptyContentView, _defaultPlayerButton],
    ]];
    [self loadPaneWithSize:NSMakeSize(kSettingsPaneWidth, kGeneralPaneHeight) grid:grid];
}

- (void)refreshFromSettings {
    [self refreshOutputPopUp];
    [self refreshDefaultPlayerButton];
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
    [DefaultAppClaim makeDefaultApp];
}

// The check walks Launch Services off the main thread, so show the last-known
// state now and correct it when the fresh answer lands.
- (void)refreshDefaultPlayerButton {
    [self renderDefaultPlayerState:_lastKnownIsDefaultPlayer];
    NSUInteger generation = ++_defaultPlayerCheckGeneration;
    __weak __typeof(self) weakSelf = self;
    [DefaultAppClaim checkIsDefaultAppForAllFileTypes:^(BOOL isDefault) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_defaultPlayerCheckGeneration) {
            return;
        }
        strongSelf->_lastKnownIsDefaultPlayer = isDefault;
        [strongSelf renderDefaultPlayerState:isDefault];
    }];
}

- (void)renderDefaultPlayerState:(BOOL)isDefault {
    // Nothing to do once Vibe already holds every type, so say so in the
    // title and disable the button rather than offer a no-op.
    _defaultPlayerButton.title = [NSString stringWithFormat:
            isDefault ? STR_SETTINGS_DEFAULT_PLAYER_IS : STR_SETTINGS_DEFAULT_PLAYER_SET, VibeAppName()];
    _defaultPlayerButton.enabled = !isDefault;
}

@end
