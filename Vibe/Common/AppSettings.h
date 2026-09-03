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

// A renderer's stable styleIdentifier, never its localized display name — see
// AudioWaveformRenderer.h. Both platforms render waveforms and both offer the
// picker, so this one is shared.
#define SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT               @"oversampling_detailed_x4"

// The waveform color theme, the palette laid over whichever style draws the
// geometry. Stable identifiers, resolved to colors in one place —
// WaveformTheme (Vibe/WaveformUI/).
#define SETTINGS_VALUE_WAVEFORM_THEME_MONO                  @"mono"
#define SETTINGS_VALUE_WAVEFORM_THEME_ORANGE                @"orange"
#define SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART             @"album_art"
#define SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM                @"custom"

// The waveform Gain reaches this far either side of 0 dB, in half-dB steps
// (SettingsRules.h).
static const double kVibeWaveformGainMaxDB = 12;

// The folder-open order's identifiers are in FolderOpenSort.h instead, beside
// the enum the app passes around — Util/NSURLUtil needs the enum and must not
// reach a setting to get it.

@interface AppSettings : NSObject

#pragma mark - Both platforms

@property(class, nonatomic, readonly) AppSettings *sharedInstance;

// Both app delegates call this; its body is macOS-only today
// (Mac/AppSettings+Mac.m).
- (void)applicationDidFinishLaunching;

// Settings > Advanced > Factory reset. Covers every AppSettings key
// and nothing else — granted-folder bookmarks, stats and window frames are
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

// The waveform's level mapping, two common settings rather than theme fields
// — they are set for a library's mastering level and must survive a theme
// switch — and on macOS one live effect, VibeSettingsLiveEffectWaveformLevels.
// Normalize (default YES) draws every track with its loudest passage at
// full height; the gain, in dB with 0 the plain mapping, applies over that.
// What each does to the bars is WaveformLevelMath.h's, which both platforms'
// renderers already draw through. The gain getter answers the half-dB ladder,
// so a knob re-reads what landed.
- (BOOL)waveformNormalize;
- (void)setWaveformNormalize:(BOOL)normalize;
- (double)waveformGainDB;
- (void)setWaveformGainDB:(double)gainDB;

// The order a folder's tracks land in the playlist — see FolderOpenSort.h.
// Normalized on read: an identifier no picker can produce reads as Name.
// Read by each shell at open time and handed to the walk, which is a path
// utility and may not read a setting itself (Util/CLAUDE.md). It governs the
// next open only; a change never reorders the playlist already on screen.
- (VibeFolderOpenSort)folderOpenSort;
- (void)setFolderOpenSort:(VibeFolderOpenSort)sort;

@end

NS_ASSUME_NONNULL_END
