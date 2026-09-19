//
//  AppSettings.h
//  Vibe
//
// Every persisted preference, as properties over NSUserDefaults. Callers
// import this header explicitly so their dependency is visible.
//
// THE PLATFORM SPLIT IS THE DIRECTORY, not a guard per property. Almost
// everything the store configures — the window, the pitch fader, the FX
// graph, Convert to FLAC, the playlist table, folder art, BPM and key
// analysis — exists only on macOS, and all of it is the (Mac) category in
// Mac/AppSettings+Mac.h, which a macOS caller imports explicitly. What both
// targets compile is the short list here, plus one #if !TARGET_OS_OSX block
// for the loose appearance keys the mac theme migration consumed. So "does
// the iOS app honor this?" is answered by which header a property sits in,
// rather than by grepping for its readers.
//

#import <Foundation/Foundation.h>
#import "FolderOpenSort.h"
#import "PlatformTypes.h"

// Nonnull by default: every string getter is backed by a registered default
// (registerDefaults covers each key), and the normalized getters snap
// unknown values to one. The nullable exceptions are marked — the
// per-appearance color pairs, whose nil means "unset, use the fallback".
NS_ASSUME_NONNULL_BEGIN

// A stable WaveformRendererRegistry identifier, never a class key or localized
// display name. Both platforms render waveforms and both offer the
// picker, so this one is shared.
#define SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT               @"oversampling_detailed_x4"

// The waveform color theme, the palette laid over whichever style draws the
// geometry. Stable identifiers, resolved to colors in one place —
// WaveformTheme (Vibe/WaveformUI/).
#define SETTINGS_VALUE_WAVEFORM_THEME_MONO                  @"mono"
#define SETTINGS_VALUE_WAVEFORM_THEME_ORANGE                @"orange"
#define SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART             @"album_art"
#define SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM                @"custom"

// The crossfade ladder Settings > Playback offers on both platforms, in
// milliseconds: 10 (instant — the declick minimum the engine always
// applies), 500 and 2000. The getter snaps a persisted value that matches no
// preset — an external defaults write — to the nearest one
// (SettingsRules.h), so the picker's selection and the engine always agree.
FOUNDATION_EXPORT const NSInteger kVibeCrossfadePresets[];
FOUNDATION_EXPORT const size_t kVibeCrossfadePresetCount;

// The folder-open order's identifiers are in FolderOpenSort.h instead, beside
// the enum the app passes around — Util/NSURLUtil needs the enum and must not
// reach a setting to get it.

@interface AppSettings : NSObject

#pragma mark - Both platforms

@property(class, nonatomic, readonly) AppSettings *sharedInstance;

// Both app delegates call this; its body is macOS-only today
// (Mac/AppSettings+Mac.m).
- (void)applicationDidFinishLaunching;

// Settings > Advanced > Reset. Preserves custom themes on macOS;
// granted-folder bookmarks, stats and window frames are
// other objects' stores. Resetting only clears the store; the caller owns the
// running-app effects and restores window shape separately, since that action
// writes geometry and its own settings.
- (BOOL)allSettingsAtDefaults;
- (void)resetToDefaults;

// iOS's loose appearance keys. On macOS the theme migration consumed them and
// currentTheme.<field> is the store of record, so they are compiled out there:
// a macOS caller fails to build instead of silently reading the registered
// default forever.
#if !TARGET_OS_OSX
- (NSString *)waveformStyle;
- (void)setWaveformStyle:(NSString *)identifier;

// The home-screen widget's own style, or nil to match the app's above. Here
// rather than in PlayerDisplaySettings for the same reason as its neighbours:
// what sends a key to that store is a macOS AppTheme field of the same name
// making an AppSettings property a lie, and the widget has no macOS
// counterpart to collide with. nil is the default and the "match app" answer;
// an empty string normalizes to it.
- (nullable NSString *)widgetWaveformStyle;
- (void)setWidgetWaveformStyle:(nullable NSString *)identifier;

// The waveform color theme, normalized on read: an identifier no picker can
// produce snaps to mono. WaveformTheme resolves it to colors.
- (NSString *)waveformTheme;
- (void)setWaveformTheme:(NSString *)identifier;

// The custom theme's colors, a played/unplayed pair per appearance —
// a single pair cannot read on both backdrops — persisted as #RRGGBB[AA],
// the alpha being the side's resting level. nil when unset or unparsable;
// WaveformTheme supplies the fallback.
- (nullable VibeColor *)waveformCustomPlayedColorForDark:(BOOL)isDark;
- (void)setWaveformCustomPlayedColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)waveformCustomUnplayedColorForDark:(BOOL)isDark;
- (void)setWaveformCustomUnplayedColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
#endif  // !TARGET_OS_OSX

// Settings > Playback > Track transitions, on both platforms. The store never
// applies either (Common/CLAUDE.md): the mac writer requests the named live
// effect, the iOS writer calls PlaybackController.applyTrackTransitionSettings.
//
// Track-change crossfade length: 10 (instant, the declick minimum), 500 or
// 2000, the stored choice the picker displays. iOS pushes it to the player as
// is; the mac pushes effectiveCrossfadeMilliseconds (Mac/AppSettings+Mac.h),
// which bit-perfect output holds at the minimum. Pause, seek and stop
// declicks never scale with it.
- (NSInteger)crossfadeMilliseconds;
- (void)setCrossfadeMilliseconds:(NSInteger)milliseconds;

// On track end. NO, the default, plays the next track in the playlist when
// one ends; YES parks on the finished track exactly as the end of the
// playlist does. Each shell enforces it at both places a track end can
// advance from (root CLAUDE.md): the successor prefetch, which is also the
// player's gapless arm point, and the end callback. A writer must then
// re-park or drop the parked handle, or a mid-track switch to Pause leaves an
// armed splice that advances anyway.
- (BOOL)pauseAtTrackEnd;
- (void)setPauseAtTrackEnd:(BOOL)pause;

// The order a folder's tracks land in the playlist — see FolderOpenSort.h.
// Normalized on read: an identifier no picker can produce reads as Name.
// Read by each shell at open time and handed to the walk, which is a path
// utility and may not read a setting itself (Util/CLAUDE.md). It governs the
// next open only; a change never reorders the playlist already on screen.
- (VibeFolderOpenSort)folderOpenSort;
- (void)setFolderOpenSort:(VibeFolderOpenSort)sort;

@end

NS_ASSUME_NONNULL_END
