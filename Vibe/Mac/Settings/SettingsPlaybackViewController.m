//
//  SettingsPlaybackViewController.m
//  Vibe
//

#import "SettingsPlaybackViewController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "Formatters.h"
#import "SettingsRules.h"
#import "MainPlayerController+Settings.h"
#import "VibeStrings.h"

static const CGFloat kPlaybackPopUpWidth = 200;

// Stable identifiers, so the debug channel can pick an item by name.
static NSString *const kOnEndPlayNext = @"play_next";
static NSString *const kOnEndPause = @"pause";

@implementation SettingsPlaybackViewController {
    NSPopUpButton *_onEndPopUp;
    NSButton *_pitchRange8;
    NSButton *_pitchRange16;
    NSPopUpButton *_skipStepsPopUp;
    NSSlider *_crossfadeSlider;
    NSTextField *_crossfadeValueLabel;
    VibeSwitch *_enableFXSwitch;
    // Their captions change with bit-perfect output, which disables both.
    SettingsRowView *_crossfadeRow;
    SettingsRowView *_enableFXRow;
    VibeSwitch *_detectBPMSwitch;
    VibeSwitch *_detectKeySwitch;
}

- (void)loadView {
    _onEndPopUp = [self popUpButtonWithWidth:kPlaybackPopUpWidth action:@selector(onEndChanged:)];
    [self addItem:STR_SETTINGS_ON_END_PLAY_NEXT value:kOnEndPlayNext to:_onEndPopUp];
    [self addItem:STR_SETTINGS_ON_END_PAUSE value:kOnEndPause to:_onEndPopUp];

    // Radio buttons group by shared action.
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

    // Off is the left end. No tick marks: thirty-one would be a smear, so the
    // action snaps the knob to the setting's steps instead.
    _crossfadeSlider = [NSSlider sliderWithValue:0 minValue:0 maxValue:kVibeCrossfadeMaxMilliseconds
                                          target:self action:@selector(crossfadeChanged:)];
    NSStackView *crossfadeCluster = [self clusterWithSlider:_crossfadeSlider width:kPlaybackPopUpWidth - 60
                                                 valueLabel:&_crossfadeValueLabel];

    _enableFXSwitch = [self switchWithAction:@selector(toggleEnableFX:)];
    _detectBPMSwitch = [self switchWithAction:@selector(toggleDetectBPM:)];
    _detectKeySwitch = [self switchWithAction:@selector(toggleDetectKey:)];

    _crossfadeRow = [SettingsRowView rowWithTitle:STR_SETTINGS_CROSSFADE_LABEL control:crossfadeCluster];
    _enableFXRow = [SettingsRowView rowWithTitle:STR_SETTINGS_ENABLE_FX control:_enableFXSwitch];
    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_TRANSITIONS_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_ON_END_LABEL control:_onEndPopUp],
            _crossfadeRow,
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_CONTROLS_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_PITCH_RANGE_LABEL control:pitchRadios],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SKIP_STEPS_LABEL control:_skipStepsPopUp],
            _enableFXRow,
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
    // The getters snap to a preset or a step, so these always match one.
    [_skipStepsPopUp selectItemWithTag:AppSettings.sharedInstance.skipBaseBars];
    [self renderCrossfade:AppSettings.sharedInstance.crossfadeMilliseconds];
    _enableFXSwitch.state = AppSettings.sharedInstance.audioFXEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    // Bit-perfect output outranks both. The caller of every refresh
    // remeasures the pane, so the captions' answers go unread.
    BOOL bitPerfect = AppSettings.sharedInstance.bitPerfectOutput;
    [SettingsRowView setControl:_crossfadeSlider enabled:!bitPerfect];
    [SettingsRowView setControl:_enableFXSwitch enabled:!bitPerfect];
    [_crossfadeRow setCaption:(bitPerfect ? STR_SETTINGS_OFF_WHILE_BIT_PERFECT : nil)];
    [_enableFXRow setCaption:(bitPerfect ? STR_SETTINGS_OFF_WHILE_BIT_PERFECT : nil)];
    _detectBPMSwitch.state = AppSettings.sharedInstance.analyzeBPM ? NSControlStateValueOn : NSControlStateValueOff;
    _detectKeySwitch.state = AppSettings.sharedInstance.analyzeKey ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)onEndChanged:(id)sender {
    AppSettings.sharedInstance.pauseAtTrackEnd = [_onEndPopUp.selectedItem.representedObject isEqual:kOnEndPause];
    // TRAP: without EndOfTrack, a mid-track switch to Pause leaves the armed
    // gapless successor, which advances anyway.
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectEndOfTrack];
}

- (void)pitchRangeChanged:(NSButton *)sender {
    AppSettings.sharedInstance.pitchRange = sender.tag;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectPitchRange];
}

- (void)skipStepsChanged:(id)sender {
    AppSettings.sharedInstance.skipBaseBars = _skipStepsPopUp.selectedTag;
}

// Only a new step is written, since each write re-arms or drops the
// successor.
- (void)crossfadeChanged:(id)sender {
    NSInteger milliseconds = VibeNormalizedCrossfadeMilliseconds(lround(_crossfadeSlider.doubleValue));
    [self renderCrossfade:milliseconds];
    if (milliseconds == AppSettings.sharedInstance.crossfadeMilliseconds) {
        return;
    }
    AppSettings.sharedInstance.crossfadeMilliseconds = milliseconds;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectCrossfade];
}

- (void)renderCrossfade:(NSInteger)milliseconds {
    _crossfadeSlider.doubleValue = milliseconds;
    _crossfadeValueLabel.stringValue = [Formatters.sharedInstance crossfadeString:milliseconds];
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
