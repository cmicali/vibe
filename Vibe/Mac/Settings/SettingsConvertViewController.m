//
//  SettingsConvertViewController.m
//  Vibe
//

#import "SettingsConvertViewController.h"
#import "AppSettings.h"
#import "VibeStrings.h"

static const CGFloat kConvertPaneHeight = 160;
static const CGFloat kConvertPopUpWidth = 220;

@implementation SettingsConvertViewController {
    NSPopUpButton *_destinationPopUp;
    NSButton *_deleteOriginalCheckbox;
}

- (void)loadView {
    _destinationPopUp = [self popUpButtonWithWidth:kConvertPopUpWidth action:@selector(destinationChanged:)];
    [_destinationPopUp addItemWithTitle:STR_SETTINGS_CONVERT_DEST_BESIDE];
    _destinationPopUp.lastItem.tag = 0;
    [_destinationPopUp addItemWithTitle:STR_SETTINGS_CONVERT_DEST_ASK];
    _destinationPopUp.lastItem.tag = 1;

    // The same setting as Convert > Delete Original After Convert; the menu's
    // checkmark and this box both read it live. Own string: checkboxes are
    // sentence case, menu items title case.
    _deleteOriginalCheckbox = [NSButton checkboxWithTitle:STR_SETTINGS_DELETE_ORIGINAL
                                                   target:self
                                                   action:@selector(toggleDeleteOriginal:)];

    NSGridView *grid = [self.class formGridWithRows:@[
        @[[NSTextField labelWithString:STR_SETTINGS_CONVERT_DEST_LABEL], _destinationPopUp],
        @[NSGridCell.emptyContentView, _deleteOriginalCheckbox],
    ]];
    [self loadPaneWithSize:NSMakeSize(kSettingsPaneWidth, kConvertPaneHeight) grid:grid];
}

- (void)refreshFromSettings {
    [_destinationPopUp selectItemWithTag:AppSettings.sharedInstance.convertAsksWhereToSave ? 1 : 0];
    _deleteOriginalCheckbox.state = AppSettings.sharedInstance.deleteOriginalAfterConvert ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)destinationChanged:(id)sender {
    AppSettings.sharedInstance.convertAsksWhereToSave = (_destinationPopUp.selectedTag == 1);
}

- (void)toggleDeleteOriginal:(id)sender {
    AppSettings.sharedInstance.deleteOriginalAfterConvert = (_deleteOriginalCheckbox.state == NSControlStateValueOn);
}

@end
