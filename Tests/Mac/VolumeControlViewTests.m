//
//  VolumeControlViewTests.m
//  VibeTests
//
//  The volume control that colors the drawn slider, with no window server.
//  NSApp is nil host-less, so sent actions go nowhere and are not asserted.
//

#import <XCTest/XCTest.h>

#import "DrawnControls.h"
#import "VolumeControlView.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AppTheme.h"
#import "Formatters.h"
#import "WaveformTheme.h"
#import "WaveformTheme+Settings.h"

@interface VolumeControlViewTests : XCTestCase
@end

@implementation VolumeControlViewTests

- (void)testTheVolumeSliderStartsAtTheStoredVolume {
    VolumeControlView *volume = [[VolumeControlView alloc] initWithFrame:NSMakeRect(0, 0, 10, 20) target:self];
    XCTAssertEqual(volume.slider.doubleValue, AppSettings.sharedInstance.volume);
    XCTAssertEqual(volume.slider.action, @selector(volumeChanged:));
    [volume applyThemedLabelColors];
    XCTAssertEqualObjects(volume.percentLabel.stringValue,
                          [Formatters.sharedInstance percentString:AppSettings.sharedInstance.volume]);
}

- (void)testTheVolumeColumnsHoldTheSliderAtTheCenter {
    AppSettings *settings = AppSettings.sharedInstance;
    BOOL saved = settings.showVolumeLabels;
    VolumeControlView *volume = [[VolumeControlView alloc] initWithFrame:NSMakeRect(0, 0, 10, 20) target:self];

    settings.showVolumeLabels = NO;
    [volume layoutColumns];
    XCTAssertEqual(NSWidth(volume.frame), 100);
    XCTAssertTrue(volume.label.hidden);

    settings.showVolumeLabels = YES;
    [volume layoutColumns];
    XCTAssertFalse(volume.label.hidden);
    XCTAssertEqualWithAccuracy(NSMidX(volume.slider.frame), NSWidth(volume.frame) / 2, 1e-9);
    XCTAssertEqual(NSWidth(volume.label.frame), NSWidth(volume.percentLabel.frame));
    settings.showVolumeLabels = saved;
}

- (void)testTheVolumeBarTakesTheThemesChoice {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    NSDictionary *saved = theme.dictionaryRepresentation;
    VolumeControlView *volume = [[VolumeControlView alloc] initWithFrame:NSMakeRect(0, 0, 10, 20) target:self];
    NSColor *art = [NSColor colorWithSRGBRed:0.1 green:0.8 blue:0.2 alpha:1];

    theme.volumeBar = SETTINGS_VALUE_VOLUME_WAVEFORM;
    theme.volumeKnob = SETTINGS_VALUE_VOLUME_KNOB_BAR;
    [volume applyColorsDark:YES artworkColor:art];
    NSColor *played = [[WaveformTheme themeForAppTheme:theme isDark:YES artworkColor:art].playedColor
            colorWithAlphaComponent:1];
    XCTAssertEqualObjects(volume.slider.trackFillColor, played, @"the waveform's played color, opaque");
    XCTAssertEqualObjects(volume.slider.knobColor, played, @"the knob follows the bar");

    theme.volumeBar = SETTINGS_VALUE_WINDOW_TINT_ARTWORK;
    [volume applyColorsDark:YES artworkColor:art];
    XCTAssertEqualObjects(volume.slider.trackFillColor, [WaveformTheme legibleArtworkColor:art isDark:YES]);

    theme.volumeBar = SETTINGS_VALUE_WINDOW_TINT_CUSTOM;
    [theme setColor:NSColor.orangeColor forBase:kVibeThemeColorVolumeBar dark:YES];
    [volume applyColorsDark:YES artworkColor:nil];
    XCTAssertEqualObjects(volume.slider.trackFillColor,
                          [theme displayColorForBase:kVibeThemeColorVolumeBar dark:YES]);

    theme.volumeBar = SETTINGS_VALUE_WINDOW_TINT_MONO;
    [volume applyColorsDark:YES artworkColor:nil];
    XCTAssertNil(volume.slider.trackFillColor, @"mono is the system's slider");
    XCTAssertEqualObjects(volume.slider.knobColor, NSColor.controlAccentColor,
                          @"same as bar under mono draws the accent, not a white knob");
    [theme replaceWithRecord:saved];
}

// The volume control's target.
- (void)volumeChanged:(id)sender {
}

@end
