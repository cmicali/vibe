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

// Key-label notation identifiers, never display names.
#define SETTINGS_VALUE_KEY_NOTATION_CAMELOT                 @"camelot"
#define SETTINGS_VALUE_KEY_NOTATION_MUSICAL                 @"musical"

// The preset ladders Settings > Playback offers, shared with the pane that
// builds its popups from them. The getters snap a persisted value that
// matches no preset — an external defaults write — to the nearest one,
// normalize-on-read like keyNotation, so the pane's selection, the engine,
// and the skip math always agree instead of the pane displaying one value
// while the audio uses another.
static const NSInteger kVibeSkipBasePresets[] = {4, 8, 16};
static const NSInteger kVibeCrossfadePresets[] = {10, 500, 2000};
static const NSInteger kVibeUIUpdateHzCapPresets[] = {3, 30, 60};

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

// YES keeps the player window above every other app's windows
// (NSFloatingWindowLevel). View > Always on Top and Settings > General share
// this setting; MainPlayerController's applyAlwaysOnTop is the one place that
// acts on it.
- (BOOL)alwaysOnTop;
- (void)setAlwaysOnTop:(BOOL)onTop;

// The right-hand time label's mode. YES shows the minus-prefixed remaining
// time, such as "-1:50", and NO, the default, shows the total duration.
// Clicking the label toggles it.
- (BOOL)showRemainingTime;
- (void)setShowRemainingTime:(BOOL)show;

// YES, the default, shows the header's file-format readout (codec, bitrate,
// sample rate) and the BPM/key line. View > Show File Info and Settings >
// Appearance share this setting; TrackDisplayController reads it at render
// time, and MainPlayerController's refreshFileInfoDisplay repaints a toggle.
- (BOOL)showFileInfo;
- (void)setShowFileInfo:(BOOL)show;

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

// The ceiling on the playback-UI tick rate, which scales itself to the
// playhead's on-screen speed (Util/UIUpdateRate.h): 3, 30 (default) or 60 Hz,
// "Playhead refresh" in Settings > Advanced. Only a short file can reach the
// ceiling — an ordinary song rests at the 3 Hz floor whatever this says — so
// 3 is the fixed rate the app ticked at before the rule existed.
- (NSInteger)uiUpdateHzCap;
- (void)setUiUpdateHzCap:(NSInteger)hz;

// NO skips tempo detection on the waveform decode pass. A file scanned while
// off caches a waveform with no BPM, so re-enabling only affects files not
// yet cached. Tagged BPM is unaffected either way.
- (BOOL)analyzeBPM;
- (void)setAnalyzeBPM:(BOOL)analyze;

// NO skips key detection on the waveform decode pass; same caching caveat as
// analyzeBPM, and a tagged key is likewise unaffected. Defaults OFF, unlike
// analyzeBPM: detection is right about half the time on real dance music
// (see Audio/CLAUDE.md), which is not good enough to put in front of someone
// unasked, while a key the file already carries always shows.
- (BOOL)analyzeKey;
- (void)setAnalyzeKey:(BOOL)analyze;

// YES draws the key label in the CDJ-style color of its Camelot number, in
// bold. Default off — the plain dimmed label matches the rest of the corner.
- (BOOL)keyColorsEnabled;
- (void)setKeyColorsEnabled:(BOOL)enabled;

// How the key label renders: VibeKeyNotationCamelot ("8A") or
// VibeKeyNotationMusical ("Am"). Stable identifiers, never display names.
// It governs every key the app shows, including one read from the file's own
// tag: a tagged "Bbm" displays as "3A" under Camelot, because the tag is
// parsed to a VibeMusicalKey at the boundary and never shown as written.
- (NSString *)keyNotation;
- (void)setKeyNotation:(NSString *)notation;

// YES makes Convert to FLAC always run the save panel instead of writing the
// FLAC silently beside the source.
- (BOOL)convertAsksWhereToSave;
- (void)setConvertAsksWhereToSave:(BOOL)ask;

// YES lets a file with no art of its own show a cover image sitting beside it —
// cover.jpg and its cousins; see FolderArtwork, which reads this. Default on,
// and it never overrides a file's own art. **Whoever writes it must then call
// MainPlayerController.refreshFolderArtwork**: the resolver caches this value,
// since it gates every accessor on every cell draw, and only that call drops
// the cached copy — so a write without it is not observed at all. Reading a
// sibling file needs a folder grant, which is why Settings > Files holds both
// this and the grants.
- (BOOL)useFolderArtwork;
- (void)setUseFolderArtwork:(BOOL)use;

@end
