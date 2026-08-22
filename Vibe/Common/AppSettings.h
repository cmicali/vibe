//
//  AppSettings.h
//  Vibe
//
// Every persisted preference, as properties over NSUserDefaults. Callers
// import this header explicitly so their dependency is visible.
//
// THE PLATFORM SPLIT IS ONE BLOCK, not a guard per property. Almost everything
// here is a macOS preference, because almost everything it configures — the
// window, the pitch fader, the FX graph, Convert to FLAC, the playlist table,
// folder art, BPM and key analysis — exists only there. What iOS compiles is
// the short list above the #if; everything below it is macOS-only. So "does
// the iOS app honor this?" is answered by which side of that line a property
// sits on, rather than by grepping for its readers.
//

#import <Foundation/Foundation.h>
#import "FolderOpenSort.h"
#import "PlatformTypes.h"

// Nonnull by default: every string getter is backed by a registered default
// (registerDefaults covers each key, the device name and UID as @""), and the
// normalized getters snap unknown values to one. The nullable exceptions are
// marked — the per-appearance color pairs, whose nil means "unset, use the
// fallback", and windowAppearance, whose nil means "track the OS setting".
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

// The folder-open order's identifiers are in FolderOpenSort.h instead, beside
// the enum the app passes around — Util/NSURLUtil needs the enum and must not
// reach a setting to get it.

#if TARGET_OS_OSX

@class NSAppearance;

#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT     @""
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT       @"light"
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK        @"dark"

// The window header's color wash. Stable identifiers, never display names:
// mono leaves the glass unwashed, artwork — the default — washes it with the
// playing track's dominant art color clamped into the appearance's band, and
// custom uses the picked color pair as picked. Only the wash follows this;
// the art color still settles, so the dock icon and the album_art waveform
// theme are the same under every choice.
#define SETTINGS_VALUE_WINDOW_TINT_MONO                     @"mono"
#define SETTINGS_VALUE_WINDOW_TINT_ARTWORK                  @"artwork"
#define SETTINGS_VALUE_WINDOW_TINT_CUSTOM                   @"custom"

// Key-label notation identifiers, never display names.
#define SETTINGS_VALUE_KEY_NOTATION_CAMELOT                 @"camelot"
#define SETTINGS_VALUE_KEY_NOTATION_MUSICAL                 @"musical"

// What a drag starting on the waveform does. Stable identifiers, never
// display names. drag_window (default) = the drag moves the window and only
// a stationary click seeks; seek = the waveform scrubs and the window stays
// put.
#define SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW                 @"drag_window"
#define SETTINGS_VALUE_WAVEFORM_DRAG_SEEK                   @"seek"

// What dragging the album art out of the window delivers. Stable identifiers,
// never display names. copy_file (default) = the audio file itself;
// copy_path = the POSIX path as text; copy_artist_title = the track's
// single-line name as text.
#define SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE               @"copy_file"
#define SETTINGS_VALUE_ARTWORK_DRAG_COPY_PATH               @"copy_path"
#define SETTINGS_VALUE_ARTWORK_DRAG_COPY_ARTIST_TITLE       @"copy_artist_title"

// The preset ladders Settings > Playback offers, shared with the pane that
// builds its popups from them. The getters snap a persisted value that
// matches no preset — an external defaults write — to the nearest one,
// normalize-on-read like keyNotation, so the pane's selection, the engine,
// and the skip math always agree instead of the pane displaying one value
// while the audio uses another.
FOUNDATION_EXPORT const NSInteger kVibeSkipBasePresets[];
FOUNDATION_EXPORT const size_t kVibeSkipBasePresetCount;
FOUNDATION_EXPORT const NSInteger kVibeCrossfadePresets[];
FOUNDATION_EXPORT const size_t kVibeCrossfadePresetCount;
FOUNDATION_EXPORT const NSInteger kVibeUIUpdateHzCapPresets[];
FOUNDATION_EXPORT const size_t kVibeUIUpdateHzCapPresetCount;

#endif  // TARGET_OS_OSX

@interface AppSettings : NSObject

#pragma mark - Both platforms

@property(class, nonatomic, readonly) AppSettings *sharedInstance;

// Both app delegates call this; its body is macOS-only today.
- (void)applicationDidFinishLaunching;

// Settings > Advanced > Factory reset. Covers every AppSettings key
// and nothing else — granted-folder bookmarks, stats and window frames are
// other objects' stores. Resetting only clears the store; the caller owns the
// live-apply, exactly as a pane writing one setting does, and window shape is
// part of that apply (MainWindow.resetToDefaultShape).
- (BOOL)allSettingsAtDefaults;
- (void)resetToDefaults;

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

// The order a folder's tracks land in the playlist — see FolderOpenSort.h.
// Normalized on read: an identifier no picker can produce reads as Name.
// Read by each shell at open time and handed to the walk, which is a path
// utility and may not read a setting itself (Util/CLAUDE.md). It governs the
// next open only; a change never reorders the playlist already on screen.
- (VibeFolderOpenSort)folderOpenSort;
- (void)setFolderOpenSort:(VibeFolderOpenSort)sort;

#if TARGET_OS_OSX

#pragma mark - macOS only

- (NSString *)audioOutputDeviceName;
- (void)setAudioOutputDeviceName:(NSString *)deviceName;

// The CoreAudio device UID, which is more robust than the name because it
// survives duplicate device names. The name is kept as a fallback for older
// settings.
- (NSString *)audioOutputDeviceUID;
- (void)setAudioOutputDeviceUID:(NSString *)deviceUID;

- (NSString *)windowAppearanceStyle;
- (void)setWindowAppearanceStyle:(NSString *)name;

// nil is the system default: a nil window appearance tracks the OS
// light/dark setting rather than pinning one.
- (nullable NSAppearance *)windowAppearance;

// The window header's color wash — see the SETTINGS_VALUE_WINDOW_TINT_*
// identifiers above. Normalized on read: an unknown stored value reads as
// artwork. ArtworkDisplayController's refreshHeaderTint is the one place that
// resolves it, and a writer must call MainPlayerController.refreshWindowTint
// to fade the wash across.
- (NSString *)windowTint;
- (void)setWindowTint:(NSString *)identifier;

// The custom tint's color, one per appearance — a wash that reads over dark
// glass silhouettes the labels over light — persisted as #RRGGBB[AA], the
// alpha being the wash's strength. nil when unset or unparsable, which
// resolves as mono, so the pane seeds it when Custom is chosen.
- (nullable VibeColor *)windowTintCustomColorForDark:(BOOL)isDark;
- (void)setWindowTintCustomColor:(nullable VibeColor *)color forDark:(BOOL)isDark;

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

// What a drag starting on the waveform does — see the SETTINGS_VALUE_WAVEFORM_DRAG_*
// identifiers above. Normalized on read: an unknown stored value reads as
// drag_window. AudioWaveformView reads it once per mouse-down.
- (NSString *)waveformDragBehavior;
- (void)setWaveformDragBehavior:(NSString *)behavior;

// What dragging the album art out of the window delivers — see the
// SETTINGS_VALUE_ARTWORK_DRAG_* identifiers above. Normalized on read: an
// unknown stored value reads as copy_file. ArtworkImageView reads it once per
// drag start.
- (NSString *)artworkDragAction;
- (void)setArtworkDragAction:(NSString *)action;

// The pitch fader's range in percent: 8 or 16, like the SL-1200MK5G's range
// button.
- (NSInteger)pitchRange;
- (void)setPitchRange:(NSInteger)range;

// Settings > Convert > Enabled: NO hides the whole Convert feature — the menu
// bar's Convert menu and the context menus' Convert to FLAC item. Default YES.
- (BOOL)convertEnabled;
- (void)setConvertEnabled:(BOOL)enabled;

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

// Settings > Playback > On track end. NO, the default, plays the next track
// in the playlist when one ends; YES parks on the finished track exactly as
// the end of the playlist does. It is enforced in one place — the successor prefetch,
// which is also the player's gapless arm point (MainPlayerController's
// successorPrefetchTrack) — so a writer must call
// MainPlayerController.applyEndOfTrackAction to re-park or drop the handle.
- (BOOL)pauseAtTrackEnd;
- (void)setPauseAtTrackEnd:(BOOL)pause;

// The ceiling on the playback-UI tick rate, which scales itself to the
// playhead's on-screen speed (Util/UIUpdateMath.h): 3, 30 (default) or
// 60 Hz, "Playhead refresh" in Settings > Advanced. Only a short file can
// reach the ceiling — an ordinary song rests at the 3 Hz floor whatever this
// says — so 3 is the fixed rate the app ticked at before the rule existed.
// The iOS screen ticks at a fixed 3 Hz and has no equivalent.
- (NSInteger)uiUpdateHzCap;
- (void)setUiUpdateHzCap:(NSInteger)hz;

// NO keeps the DJ performance-FX graph segment — low kill, reverb and delay
// returns — out of the audio engine entirely: AudioPlayer is created with FX
// off, fx reads nil, and the main mixer wires straight to the output. The FX
// menu is omitted from the menu bar and the Q/W/E/R/T keys pass through
// unhandled. Read once at launch, so a change applies on relaunch. iOS passes
// a hard NO and never consults this; see PlayerViewController.
- (BOOL)audioFXEnabled;
- (void)setAudioFXEnabled:(BOOL)enabled;

// NO skips tempo detection on the waveform decode pass. A file scanned while
// off caches a waveform with no BPM, so re-enabling only affects files not
// yet cached. Tagged BPM is unaffected either way. The loader is TOLD the
// answer through its analysis provider rather than reading it here, so iOS —
// which never analyzes — never consults this; see AudioWaveformLoader.
- (BOOL)analyzeBPM;
- (void)setAnalyzeBPM:(BOOL)analyze;

// NO skips key detection on the waveform decode pass; same caching caveat as
// analyzeBPM, and a tagged key is likewise unaffected. Defaults OFF, unlike
// analyzeBPM: detection is right about half the time on real dance music
// (see Audio/CLAUDE.md), which is not good enough to put in front of someone
// unasked, while a key the file already carries always shows.
- (BOOL)analyzeKey;
- (void)setAnalyzeKey:(BOOL)analyze;

// Whether the header shows the tempo at all. Default on; off, the BPM half of
// the header's readout is blank. Detection is Playback's analyzeBPM — this
// only hides the readout, and the delay's BPM-synced taps still follow the
// track's tempo.
- (BOOL)showBPM;
- (void)setShowBPM:(BOOL)show;

// Whether the header shows the musical key at all. Default on; off, the
// notation and color settings below have nothing to govern. Detection is
// Playback's analyzeKey — this only hides the readout.
- (BOOL)showKey;
- (void)setShowKey:(BOOL)show;

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
// cover.jpg and its cousins; see FolderArtResolver, which reads this. Default on,
// and it never overrides a file's own art. **Whoever writes it must then call
// MainPlayerController.refreshFolderArt**: the resolver caches this value,
// since it gates every accessor on every cell draw, and only that call drops
// the cached copy — so a write without it is not observed at all. Reading a
// sibling file needs a folder grant, which is why Settings > Files holds both
// this and the grants. Folder art is macOS-only; iOS leaves AudioTrackArtwork's
// resolver handle nil and shows embedded art alone.
- (BOOL)useFolderArt;
- (void)setUseFolderArt:(BOOL)use;

#endif  // TARGET_OS_OSX

@end

NS_ASSUME_NONNULL_END
