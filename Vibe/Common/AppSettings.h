//
//  AppSettings.h
//  Vibe
//
// Every persisted preference, as properties over NSUserDefaults. Callers
// import this header explicitly so their dependency is visible.
//
// The platform split is the header: macOS-only settings are the (Mac)
// category in Mac/AppSettings+Mac.h; this one holds what both targets compile,
// plus the iOS-only block below.
//

#import <Foundation/Foundation.h>
#import "FolderOpenSort.h"
#import "RepeatMode.h"
#import "PlatformTypes.h"

// Nonnull by default: every string getter has a registered default or
// normalizes to one. Nullable ones are marked.
NS_ASSUME_NONNULL_BEGIN

// A stable WaveformRendererRegistry identifier, never a display name.
#define SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT               @"oversampling_detailed_x4"
#define SETTINGS_VALUE_WIDGET_WAVEFORM_STYLE_DEFAULT        @"wiggle_centered"

// Waveform color theme identifiers, resolved to colors only by WaveformTheme.
#define SETTINGS_VALUE_WAVEFORM_THEME_MONO                  @"mono"
#define SETTINGS_VALUE_WAVEFORM_THEME_ORANGE                @"orange"
#define SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART             @"album_art"
#define SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM                @"custom"

// The crossfade ladder in milliseconds; 10 is instant, the declick minimum.
// The getter snaps any other stored value to the nearest preset.
FOUNDATION_EXPORT const NSInteger kVibeCrossfadePresets[];
FOUNDATION_EXPORT const size_t kVibeCrossfadePresetCount;

@interface AppSettings : NSObject

#pragma mark - Both platforms

@property(class, nonatomic, readonly) AppSettings *sharedInstance;

// iOS-only. On macOS the theme migration consumed these keys, so a macOS
// caller fails to build rather than reading a dead key; use currentTheme.
#if !TARGET_OS_OSX
- (NSString *)waveformStyle;
- (void)setWaveformStyle:(NSString *)identifier;

// The home-screen widget's own style, Wiggle by default; nil matches the
// app's, stored as an empty string so it outranks the registered default.
- (nullable NSString *)widgetWaveformStyle;
- (void)setWidgetWaveformStyle:(nullable NSString *)identifier;

// Normalized on read: an unknown identifier snaps to mono.
- (NSString *)waveformTheme;
- (void)setWaveformTheme:(NSString *)identifier;

// The custom theme's played/unplayed pair per appearance, as #RRGGBB[AA] with
// the alpha the side's resting level. nil when unset or unparsable.
- (nullable VibeColor *)waveformCustomPlayedColorForDark:(BOOL)isDark;
- (void)setWaveformCustomPlayedColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)waveformCustomUnplayedColorForDark:(BOOL)isDark;
- (void)setWaveformCustomUnplayedColor:(nullable VibeColor *)color forDark:(BOOL)isDark;

#endif  // !TARGET_OS_OSX

// Track transitions. The store never applies either: the mac writer requests
// the live effect, the iOS writer calls
// PlaybackController.applyTrackTransitionSettings.
//
// The stored crossfade choice. The mac pushes effectiveCrossfadeMilliseconds
// instead, which bit-perfect output holds at the minimum.
- (NSInteger)crossfadeMilliseconds;
- (void)setCrossfadeMilliseconds:(NSInteger)milliseconds;

// YES parks on the finished track as the end of the playlist does. Each shell
// enforces it at the successor prefetch and the end callback (root
// AGENTS.md); a writer must re-park, or a mid-track switch to Pause leaves an
// armed gapless splice that advances anyway.
- (BOOL)pauseAtTrackEnd;
- (void)setPauseAtTrackEnd:(BOOL)pause;

// Transport state, both platforms, toggled while listening rather than set in
// Settings: Playback-menu items on the mac, the card's buttons on iOS. Each
// shell pushes them into its Playlist and re-parks the successor through the
// same apply as pauseAtTrackEnd, which outranks both: Pause parks whatever
// repeat says. A writer that skips the apply leaves an armed gapless splice
// into the old successor.
- (VibeRepeatMode)repeatMode;
- (void)setRepeatMode:(VibeRepeatMode)mode;
- (BOOL)shuffleEnabled;
- (void)setShuffleEnabled:(BOOL)enabled;

// Settings > Playback > Enable audio effects, both platforms, default YES:
// whether the DJ FX segment is in the render. The store never applies it:
// the mac writer requests its live effect, the iOS writer calls
// PlaybackController.applyFXSetting. On the mac audioFXAllowed
// (Mac/AppSettings+Mac.h) folds in bit-perfect output, which outranks this.
- (BOOL)audioFXEnabled;
- (void)setAudioFXEnabled:(BOOL)enabled;

// Settings > Playback > Detect BPM automatically, both platforms, default
// YES. NO skips tempo detection. A file scanned while off caches no BPM, so
// re-enabling reaches only uncached files. The loader is told through its
// analysis provider rather than reading this. Key detection is macOS-only
// (analyzeKey, Mac/AppSettings+Mac.h).
- (BOOL)analyzeBPM;
- (void)setAnalyzeBPM:(BOOL)analyze;

// Normalized on read: an unknown identifier reads as Name. Each shell reads it
// at open time and hands it to the walk; a change never reorders the
// playlist on screen.
- (VibeFolderOpenSort)folderOpenSort;
- (void)setFolderOpenSort:(VibeFolderOpenSort)sort;

@end

NS_ASSUME_NONNULL_END
