//
//  SettingsConvertViewController.m
//  Vibe
//

#import "SettingsConvertViewController.h"
#import "AppSettings.h"
#import "MainPlayerController+Settings.h"
#import "VibeStrings.h"

static const CGFloat kConvertPopUpWidth = 220;

@implementation SettingsConvertViewController {
    NSSwitch *_enabledSwitch;
    NSPopUpButton *_destinationPopUp;
    NSSwitch *_deleteOriginalSwitch;
}

- (void)loadView {
    _enabledSwitch = [self switchWithAction:@selector(toggleEnabled:)];

    _destinationPopUp = [self popUpButtonWithWidth:kConvertPopUpWidth action:@selector(destinationChanged:)];
    [_destinationPopUp addItemWithTitle:STR_SETTINGS_CONVERT_DEST_BESIDE];
    _destinationPopUp.lastItem.tag = 0;
    [_destinationPopUp addItemWithTitle:STR_SETTINGS_CONVERT_DEST_ASK];
    _destinationPopUp.lastItem.tag = 1;

    // The same setting as Convert > Delete Original After Convert; the menu's
    // checkmark and this row both read it live. Own string: rows are sentence
    // case, menu items title case.
    _deleteOriginalSwitch = [self switchWithAction:@selector(toggleDeleteOriginal:)];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_CONVERT_ENABLED control:_enabledSwitch],
        ]],
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_CONVERT_DEST_LABEL control:_destinationPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_DELETE_ORIGINAL control:_deleteOriginalSwitch],
        ]],
    ]];
}

- (void)refreshFromSettings {
    BOOL enabled = AppSettings.sharedInstance.convertEnabled;
    _enabledSwitch.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    _destinationPopUp.enabled = enabled;
    _deleteOriginalSwitch.enabled = enabled;
    [_destinationPopUp selectItemWithTag:AppSettings.sharedInstance.convertAsksWhereToSave ? 1 : 0];
    _deleteOriginalSwitch.state = AppSettings.sharedInstance.deleteOriginalAfterConvert ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleEnabled:(id)sender {
    AppSettings.sharedInstance.convertEnabled = (_enabledSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectConvertMenu];
    [self refreshFromSettings];
}

- (void)destinationChanged:(id)sender {
    AppSettings.sharedInstance.convertAsksWhereToSave = (_destinationPopUp.selectedTag == 1);
}

- (void)toggleDeleteOriginal:(id)sender {
    AppSettings.sharedInstance.deleteOriginalAfterConvert = (_deleteOriginalSwitch.state == NSControlStateValueOn);
}

@end
