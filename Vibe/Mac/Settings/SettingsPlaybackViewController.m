//
//  SettingsPlaybackViewController.m
//  Vibe
//

#import "SettingsPlaybackViewController.h"
#import "AppSettings.h"
#import "AudioPlayer.h"
#import "MainPlayerController.h"
#import "VibeStrings.h"

static const CGFloat kPlaybackPaneHeight = 270;
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
    NSButton *_enableFXCheckbox;
    NSButton *_detectBPMCheckbox;
    NSButton *_detectKeyCheckbox;
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

    // The player reads this once at init, so the toggle lands on the next
    // launch; the caption below says so.
    _enableFXCheckbox = [NSButton checkboxWithTitle:STR_SETTINGS_ENABLE_FX
                                             target:self action:@selector(toggleEnableFX:)];
    NSTextField *fxRestartCaption = [NSTextField labelWithString:
            [NSString stringWithFormat:STR_SETTINGS_ENABLE_FX_RESTART, VibeAppName()]];
    fxRestartCaption.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    fxRestartCaption.textColor = [NSColor secondaryLabelColor];

    _detectBPMCheckbox = [NSButton checkboxWithTitle:STR_SETTINGS_DETECT_BPM
                                              target:self action:@selector(toggleDetectBPM:)];
    _detectKeyCheckbox = [NSButton checkboxWithTitle:STR_SETTINGS_DETECT_KEY
                                              target:self action:@selector(toggleDetectKey:)];

    // How the key is written and colored is Appearance's business; this pane
    // only decides whether it is detected at all.
    NSGridView *grid = [self.class formGridWithRows:@[
        @[[NSTextField labelWithString:STR_SETTINGS_ON_END_LABEL], _onEndPopUp],
        @[[NSTextField labelWithString:STR_SETTINGS_PITCH_RANGE_LABEL], pitchRadios],
        @[[NSTextField labelWithString:STR_SETTINGS_SKIP_STEPS_LABEL], _skipStepsPopUp],
        @[[NSTextField labelWithString:STR_SETTINGS_CROSSFADE_LABEL], _crossfadePopUp],
        @[NSGridCell.emptyContentView, _enableFXCheckbox],
        @[NSGridCell.emptyContentView, fxRestartCaption],
        @[NSGridCell.emptyContentView, _detectBPMCheckbox],
        @[NSGridCell.emptyContentView, _detectKeyCheckbox],
    ]];
    [self loadPaneWithSize:NSMakeSize(kSettingsPaneWidth, kPlaybackPaneHeight) grid:grid];
}

- (void)refreshFromSettings {
    NSString *onEnd = AppSettings.sharedInstance.pauseAtTrackEnd ? kOnEndPause : kOnEndPlayNext;
    [_onEndPopUp selectItemAtIndex:[_onEndPopUp indexOfItemWithRepresentedObject:onEnd]];
    NSInteger range = AppSettings.sharedInstance.pitchRange;
    _pitchRange8.state = range != 16 ? NSControlStateValueOn : NSControlStateValueOff;
    _pitchRange16.state = range == 16 ? NSControlStateValueOn : NSControlStateValueOff;
    // The getters snap to a preset, so these always match an item.
    [_skipStepsPopUp selectItemWithTag:AppSettings.sharedInstance.skipBaseBars];
    [_crossfadePopUp selectItemWithTag:AppSettings.sharedInstance.crossfadeMilliseconds];
    _enableFXCheckbox.state = AppSettings.sharedInstance.audioFXEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _detectBPMCheckbox.state = AppSettings.sharedInstance.analyzeBPM ? NSControlStateValueOn : NSControlStateValueOff;
    _detectKeyCheckbox.state = AppSettings.sharedInstance.analyzeKey ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)onEndChanged:(id)sender {
    AppSettings.sharedInstance.pauseAtTrackEnd = [_onEndPopUp.selectedItem.representedObject isEqual:kOnEndPause];
    // The live half: a mid-track change must re-park or drop the successor
    // handle, or an already-armed splice would advance past the end anyway.
    [self.playerController applyEndOfTrackAction];
}

- (void)pitchRangeChanged:(NSButton *)sender {
    AppSettings.sharedInstance.pitchRange = sender.tag;
    // The live half: re-clamps the pitch and redraws the fader scale.
    [self.playerController applyPitchRange];
}

- (void)skipStepsChanged:(id)sender {
    AppSettings.sharedInstance.skipBaseBars = _skipStepsPopUp.selectedTag;
}

- (void)crossfadeChanged:(id)sender {
    NSInteger milliseconds = _crossfadePopUp.selectedTag;
    AppSettings.sharedInstance.crossfadeMilliseconds = milliseconds;
    self.playerController.audioPlayer.crossfadeMilliseconds = milliseconds;
}

- (void)toggleEnableFX:(id)sender {
    AppSettings.sharedInstance.audioFXEnabled = (_enableFXCheckbox.state == NSControlStateValueOn);
}

- (void)toggleDetectBPM:(id)sender {
    AppSettings.sharedInstance.analyzeBPM = (_detectBPMCheckbox.state == NSControlStateValueOn);
}

- (void)toggleDetectKey:(id)sender {
    AppSettings.sharedInstance.analyzeKey = (_detectKeyCheckbox.state == NSControlStateValueOn);
}

@end
