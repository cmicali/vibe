//
//  SettingsPlaybackViewController.m
//  Vibe
//

#import "SettingsPlaybackViewController.h"
#import "AudioPlayer.h"
#import "MainPlayerController.h"
#import "VibeStrings.h"

static const CGFloat kPlaybackPaneHeight = 240;
static const CGFloat kPlaybackPopUpWidth = 200;

// The skip presets: the smallest skip's bar count; the three sizes are the
// base, twice it and four times it.
static const NSInteger kSkipBasePresets[] = {4, 8, 16};

// The crossfade presets, in milliseconds. 10 is the declick minimum the
// engine always applies — effectively instant.
static const NSInteger kCrossfadePresets[] = {10, 500, 2000};

@implementation SettingsPlaybackViewController {
    NSButton *_pitchRange8;
    NSButton *_pitchRange16;
    NSPopUpButton *_skipStepsPopUp;
    NSPopUpButton *_crossfadePopUp;
    NSButton *_detectBPMCheckbox;
}

- (void)loadView {
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
    for (size_t i = 0; i < sizeof(kSkipBasePresets) / sizeof(kSkipBasePresets[0]); i++) {
        NSInteger base = kSkipBasePresets[i];
        [_skipStepsPopUp addItemWithTitle:[NSString stringWithFormat:STR_SETTINGS_SKIP_STEPS_OPTION,
                                           (long)base, (long)(base * 2), (long)(base * 4)]];
        _skipStepsPopUp.lastItem.tag = base;
    }

    _crossfadePopUp = [self popUpButtonWithWidth:kPlaybackPopUpWidth action:@selector(crossfadeChanged:)];
    NSArray<NSString *> *crossfadeTitles = @[STR_SETTINGS_CROSSFADE_INSTANT,
                                             STR_SETTINGS_CROSSFADE_SHORT,
                                             STR_SETTINGS_CROSSFADE_LONG];
    for (NSUInteger i = 0; i < crossfadeTitles.count; i++) {
        [_crossfadePopUp addItemWithTitle:crossfadeTitles[i]];
        _crossfadePopUp.lastItem.tag = kCrossfadePresets[i];
    }

    _detectBPMCheckbox = [NSButton checkboxWithTitle:STR_SETTINGS_DETECT_BPM
                                              target:self action:@selector(toggleDetectBPM:)];

    NSGridView *grid = [self.class formGridWithRows:@[
        @[[NSTextField labelWithString:STR_SETTINGS_PITCH_RANGE_LABEL], pitchRadios],
        @[[NSTextField labelWithString:STR_SETTINGS_SKIP_STEPS_LABEL], _skipStepsPopUp],
        @[[NSTextField labelWithString:STR_SETTINGS_CROSSFADE_LABEL], _crossfadePopUp],
        @[NSGridCell.emptyContentView, _detectBPMCheckbox],
    ]];
    [self loadPaneWithSize:NSMakeSize(kSettingsPaneWidth, kPlaybackPaneHeight) grid:grid];
}

- (void)refreshFromSettings {
    NSInteger range = Settings.pitchRange;
    _pitchRange8.state = range != 16 ? NSControlStateValueOn : NSControlStateValueOff;
    _pitchRange16.state = range == 16 ? NSControlStateValueOn : NSControlStateValueOff;
    if (![_skipStepsPopUp selectItemWithTag:Settings.skipBaseBars]) {
        [_skipStepsPopUp selectItemWithTag:8];
    }
    if (![_crossfadePopUp selectItemWithTag:Settings.crossfadeMilliseconds]) {
        [_crossfadePopUp selectItemWithTag:kCrossfadePresets[0]];
    }
    _detectBPMCheckbox.state = Settings.analyzeBPM ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)pitchRangeChanged:(NSButton *)sender {
    Settings.pitchRange = sender.tag;
    // The live half: re-clamps the pitch and redraws the fader scale.
    [self.playerController applyPitchRange];
}

- (void)skipStepsChanged:(id)sender {
    Settings.skipBaseBars = _skipStepsPopUp.selectedTag;
}

- (void)crossfadeChanged:(id)sender {
    NSInteger milliseconds = _crossfadePopUp.selectedTag;
    Settings.crossfadeMilliseconds = milliseconds;
    self.playerController.audioPlayer.crossfadeMilliseconds = milliseconds;
}

- (void)toggleDetectBPM:(id)sender {
    Settings.analyzeBPM = (_detectBPMCheckbox.state == NSControlStateValueOn);
}

@end
