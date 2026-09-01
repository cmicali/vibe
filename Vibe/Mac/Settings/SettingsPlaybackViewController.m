//
//  SettingsPlaybackViewController.m
//  Vibe
//

#import "SettingsPlaybackViewController.h"
#import "AppSettings.h"
#import "AudioPlayer.h"
#import "MainPlayerController+Settings.h"
#import "VibeStrings.h"

static const CGFloat kPlaybackPopUpWidth = 200;

// Stable identifiers on the On track end items, never their localized titles,
// so the debug channel can pick one by name.
static NSString *const kOnEndPlayNext = @"play_next";
static NSString *const kOnEndPause = @"pause";

// The preset values live in AppSettings.h (kVibeSkipBasePresets: the smallest
// skip's bar count, the three sizes being the base, twice and four times it;
// kVibeCrossfadePresets in milliseconds, 10 the declick minimum the engine
// always applies — effectively instant), because the getters snap persisted
// values to them.

@implementation SettingsPlaybackViewController {
    NSPopUpButton *_onEndPopUp;
    NSButton *_pitchRange8;
    NSButton *_pitchRange16;
    NSPopUpButton *_skipStepsPopUp;
    NSPopUpButton *_crossfadePopUp;
    NSSwitch *_enableFXSwitch;
    NSSwitch *_detectBPMSwitch;
    NSSwitch *_detectKeySwitch;
}

- (void)loadView {
    _onEndPopUp = [self popUpButtonWithWidth:kPlaybackPopUpWidth action:@selector(onEndChanged:)];
    [_onEndPopUp addItemWithTitle:STR_SETTINGS_ON_END_PLAY_NEXT];
    _onEndPopUp.lastItem.representedObject = kOnEndPlayNext;
    [_onEndPopUp addItemWithTitle:STR_SETTINGS_ON_END_PAUSE];
    _onEndPopUp.lastItem.representedObject = kOnEndPause;

    // Radio buttons group by shared action, which is exactly what these two
    // have.
    _pitchRange8 = [NSButton radioButtonWithTitle:STR_MENU_PITCH_RANGE_8
                                           target:self action:@selector(pitchRangeChanged:)];
    _pitchRange8.tag = 8;
    _pitchRange16 = [NSButton radioButtonWithTitle:STR_MENU_PITCH_RANGE_16
                                            target:self action:@selector(pitchRangeChanged:)];
    _pitchRange16.tag = 16;
    NSStackView *pitchRadios = [NSStackView stackViewWithViews:@[_pitchRange8, _pitchRange16]];
    pitchRadios.spacing = 12;

    _skipStepsPopUp = [self popUpButtonWithWidth:kPlaybackPopUpWidth action:@selector(skipStepsChanged:)];
    for (size_t i = 0; i < kVibeSkipBasePresetCount; i++) {
        NSInteger base = kVibeSkipBasePresets[i];
        [_skipStepsPopUp addItemWithTitle:[NSString stringWithFormat:STR_SETTINGS_SKIP_STEPS_OPTION,
                                           (long)base, (long)(base * 2), (long)(base * 4)]];
        _skipStepsPopUp.lastItem.tag = base;
    }

    _crossfadePopUp = [self popUpButtonWithWidth:kPlaybackPopUpWidth action:@selector(crossfadeChanged:)];
    NSArray<NSString *> *crossfadeTitles = @[STR_SETTINGS_CROSSFADE_INSTANT,
                                             STR_SETTINGS_CROSSFADE_SHORT,
                                             STR_SETTINGS_CROSSFADE_LONG];
    NSAssert(crossfadeTitles.count == kVibeCrossfadePresetCount,
             @"Every crossfade preset needs a title");
    for (size_t i = 0; i < kVibeCrossfadePresetCount; i++) {
        [_crossfadePopUp addItemWithTitle:crossfadeTitles[i]];
        _crossfadePopUp.lastItem.tag = kVibeCrossfadePresets[i];
    }

    // A missing graph can only be added on the next launch. When it already
    // exists, the switch changes the controls and their state immediately.
    _enableFXSwitch = [self switchWithAction:@selector(toggleEnableFX:)];
    _detectBPMSwitch = [self switchWithAction:@selector(toggleDetectBPM:)];
    // How the key is written and colored is Appearance's business; this pane
    // only decides whether it is detected at all.
    _detectKeySwitch = [self switchWithAction:@selector(toggleDetectKey:)];

    NSString *fxCaption = self.playerController.audioPlayer.fx
            ? nil
            : [NSString stringWithFormat:STR_SETTINGS_ENABLE_FX_RESTART, VibeAppName()];
    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_ON_END_LABEL control:_onEndPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_CROSSFADE_LABEL control:_crossfadePopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_PITCH_RANGE_LABEL control:pitchRadios],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SKIP_STEPS_LABEL control:_skipStepsPopUp],
        ]],
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_ENABLE_FX
                                  caption:fxCaption
                                  control:_enableFXSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_ANALYSIS_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_DETECT_BPM control:_detectBPMSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_DETECT_KEY control:_detectKeySwitch],
        ]],
    ]];
}

- (void)refreshFromSettings {
    NSString *onEnd = AppSettings.sharedInstance.pauseAtTrackEnd ? kOnEndPause : kOnEndPlayNext;
    [self selectValue:onEnd in:_onEndPopUp];
    NSInteger range = AppSettings.sharedInstance.pitchRange;
    _pitchRange8.state = range != 16 ? NSControlStateValueOn : NSControlStateValueOff;
    _pitchRange16.state = range == 16 ? NSControlStateValueOn : NSControlStateValueOff;
    // The getters snap to a preset, so these always match an item.
    [_skipStepsPopUp selectItemWithTag:AppSettings.sharedInstance.skipBaseBars];
    [_crossfadePopUp selectItemWithTag:AppSettings.sharedInstance.crossfadeMilliseconds];
    _enableFXSwitch.state = AppSettings.sharedInstance.audioFXEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _detectBPMSwitch.state = AppSettings.sharedInstance.analyzeBPM ? NSControlStateValueOn : NSControlStateValueOff;
    _detectKeySwitch.state = AppSettings.sharedInstance.analyzeKey ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)onEndChanged:(id)sender {
    AppSettings.sharedInstance.pauseAtTrackEnd = [_onEndPopUp.selectedItem.representedObject isEqual:kOnEndPause];
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectEndOfTrack];
}

- (void)pitchRangeChanged:(NSButton *)sender {
    AppSettings.sharedInstance.pitchRange = sender.tag;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectPitchRange];
}

- (void)skipStepsChanged:(id)sender {
    AppSettings.sharedInstance.skipBaseBars = _skipStepsPopUp.selectedTag;
}

- (void)crossfadeChanged:(id)sender {
    AppSettings.sharedInstance.crossfadeMilliseconds = _crossfadePopUp.selectedTag;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectCrossfade];
}

- (void)toggleEnableFX:(id)sender {
    AppSettings.sharedInstance.audioFXEnabled = (_enableFXSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectFXControls];
}

- (void)toggleDetectBPM:(id)sender {
    AppSettings.sharedInstance.analyzeBPM = (_detectBPMSwitch.state == NSControlStateValueOn);
}

- (void)toggleDetectKey:(id)sender {
    AppSettings.sharedInstance.analyzeKey = (_detectKeySwitch.state == NSControlStateValueOn);
}

@end
