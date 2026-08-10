//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#if TARGET_OS_OSX
@class NSAppearance;
#endif

// A renderer's stable styleIdentifier, never its localized display name — see
// AudioWaveformRenderer.h.
#define SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT               @"oversampling_detailed_x4"

#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT     @""
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT       @"light"
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK        @"dark"

@interface AppSettings : NSObject

+ (AppSettings*)sharedInstance;

- (void)applicationDidFinishLaunching;

- (NSString *)audioOutputDeviceName;
- (void)setAudioOutputDeviceName:(NSString *)deviceName;

// The CoreAudio device UID, which is more robust than the name because it
// survives duplicate device names. The name is kept as a fallback for older
// settings.
- (NSString *)audioOutputDeviceUID;
- (void)setAudioOutputDeviceUID:(NSString *)deviceUID;

- (NSString *)windowAppearanceStyle;
- (void)setWindowAppearanceStyle:(NSString *)name;

#if TARGET_OS_OSX
- (NSAppearance *)windowAppearance;
#endif

- (NSString *)waveformStyle;
- (void)setWaveformStyle:(NSString *)identifier;

- (BOOL)isPitchPanelShown;
- (void)setPitchPanelShown:(BOOL)shown;

- (BOOL)isPlaylistShown;
- (void)setPlaylistShown:(BOOL)shown;

// The right-hand time label's mode. YES shows the minus-prefixed remaining
// time, such as "-1:50", and NO, the default, shows the total duration.
// Clicking the label toggles it.
- (BOOL)showRemainingTime;
- (void)setShowRemainingTime:(BOOL)show;

// The pitch fader's range in percent: 8 or 16, like the SL-1200MK5G's range
// button.
- (NSInteger)pitchRange;
- (void)setPitchRange:(NSInteger)range;

// Convert > Delete Original: YES sends a converted source file to the Trash
// once its FLAC is in place. Governs every conversion path.
- (BOOL)deleteOriginalAfterConvert;
- (void)setDeleteOriginalAfterConvert:(BOOL)deleteOriginal;

// The smallest skip's bar count: 4, 8 or 16. The three skip sizes are this,
// twice it and four times it; the tempo-unknown wall-clock fallbacks
// (10/30/60s) do not scale with it.
- (NSInteger)skipBaseBars;
- (void)setSkipBaseBars:(NSInteger)bars;

// Track-change crossfade length: 10 (instant, the declick minimum), 500 or
// 2000. Applied to AudioPlayer.crossfadeMilliseconds by whoever writes it;
// pause, seek and stop declicks never scale with it.
- (NSInteger)crossfadeMilliseconds;
- (void)setCrossfadeMilliseconds:(NSInteger)milliseconds;

// NO skips tempo detection on the waveform decode pass. A file scanned while
// off caches a waveform with no BPM, so re-enabling only affects files not
// yet cached. Tagged BPM is unaffected either way.
- (BOOL)analyzeBPM;
- (void)setAnalyzeBPM:(BOOL)analyze;

// YES makes Convert to FLAC always run the save panel instead of writing the
// FLAC silently beside the source.
- (BOOL)convertAsksWhereToSave;
- (void)setConvertAsksWhereToSave:(BOOL)ask;

@end
