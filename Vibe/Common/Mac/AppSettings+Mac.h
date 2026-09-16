//
//  AppSettings+Mac.h
//  Vibe
//
//  The macOS half of AppSettings: every preference only the mac app has —
//  the window, the pitch fader, the FX graph, Convert to FLAC, the playlist
//  table, folder art, BPM and key analysis — and the theme store. What both
//  platforms compile is AppSettings.h; a macOS caller of anything here
//  imports this header explicitly, so its dependency is visible.
//

#import "AppSettings.h"
#import "AppTheme.h"

// Nonnull by default, as in AppSettings.h: every string getter is backed by a
// registered default (the device name and UID as @""), and the normalized
// getters snap unknown values to one. The nullable exceptions are marked —
// windowAppearance, whose nil means "track the OS setting", and the preview
// style it answers over, whose nil means "no preview held".
NS_ASSUME_NONNULL_BEGIN

@class NSAppearance;


// The window's appearance setting: "" follows the OS, light and dark pin it.
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

@interface AppSettings (Mac)

#pragma mark - macOS only

- (NSString *)audioOutputDeviceName;
- (void)setAudioOutputDeviceName:(NSString *)deviceName;

// The CoreAudio device UID, which is more robust than the name because it
// survives duplicate device names. The name is kept as a fallback for older
// settings.
- (NSString *)audioOutputDeviceUID;
- (void)setAudioOutputDeviceUID:(NSString *)deviceUID;

// "" (Auto, the default) tracks the OS light/dark setting; light and dark pin
// the main window. A common setting, deliberately outside the theme — a theme
// decides its COLORS' mode (AppTheme.mode), never the window's appearance.
- (NSString *)windowAppearanceStyle;
- (void)setWindowAppearanceStyle:(NSString *)name;

// nil is the system default: a nil window appearance tracks the OS
// light/dark setting rather than pinning one. It answers the preview below
// over the stored style while one is held, and a single-mode theme's pin
// (AppTheme.requiredWindowAppearance) over both — the one place the window's
// appearance is decided, so the window, the menu and the Settings toolbar's
// preview toggle cannot disagree.
- (nullable NSAppearance *)windowAppearance;

// The Settings window's Appearance page holds a temporary light/dark preview
// while it is on screen, so a theme's other palette can be looked at without
// the visit changing what the app looks like afterwards. Nothing persists it,
// windowAppearanceStyle keeps reporting the stored choice, and writing that
// style clears the preview — an explicit choice can never land under a stale
// one. A writer requests VibeSettingsLiveEffectWindowAppearance, as for any
// other appearance write.
- (nullable NSString *)windowAppearancePreviewStyle;
- (void)setWindowAppearancePreviewStyle:(nullable NSString *)name;

// YES, the default, shows the custom close and minimize traffic lights in the
// main window. A writer requests VibeSettingsLiveEffectTrafficLights so the
// already-built controls update immediately.
- (BOOL)showTrafficLights;
- (void)setShowTrafficLights:(BOOL)show;


#pragma mark Themes

// The themed appearance fields — window tint, info-display toggles, key
// notation and colors, waveform style and palette, fonts, playlist colors,
// window chrome — are AppTheme's, read through currentTheme below. They have
// no loose accessors here; the pre-theme keys are migrated at init and
// consumed.

// The one working theme every appearance consumer reads. Materialized once
// from the stored working record — or, when none diverges, from the active
// theme's record — and mutated in place from then on. Main thread only, like
// every reader of it.
- (AppTheme *)currentTheme;

// The named theme the working state derives from: a built-in identifier or a
// user theme's minted id, snapped to vibe when it names neither.
- (NSString *)activeThemeIdentifier;

// Built-ins first, then the user themes in creation order.
- (NSArray<NSString *> *)orderedThemeIdentifiers;

// A user theme's stored name; the built-ins' localized names. nil for an
// identifier that names nothing.
- (nullable NSString *)displayNameForThemeIdentifier:(NSString *)identifier;

// The named theme's sanitized sparse record — what export serializes and
// apply installs. An unknown identifier answers vibe's (the empty record).
- (NSDictionary<NSString *, id> *)recordForThemeIdentifier:(NSString *)identifier;

// The theme editor's undo. currentThemeDidChange pushes the stored entry
// each edit of a USER theme replaced — fields and name, so a committed
// rename (renameUserThemeWithIdentifier:toName:) is an entry too — and a
// continuous gesture's ticks (the continuous form below), moving the same
// keys within two seconds of each other, coalesce onto the first tick's
// entry, while discrete edits never do, so two menu picks of one field are
// two undos; fifty deep. A theme apply drops the stack, so an undo never
// lands on another theme, and a built-in's edits are divergence rather than
// the theme's and are not recorded. undoThemeEdit puts the top entry's name
// and fields back and persists them without recording; the caller requests
// ThemeApply. The image sweep keeps a custom image a stacked entry still
// names, so an undo can put a cleared picture back.
@property (readonly, nonatomic) BOOL canUndoThemeEdit;
- (void)undoThemeEdit;

// Repopulates currentTheme from the named record and makes it active. Store
// only — the caller requests VibeSettingsLiveEffectThemeApply, per the
// store-first contract.
- (void)applyThemeWithIdentifier:(NSString *)identifier;

// The one persist funnel: every currentTheme field edit calls this after
// writing the field. The working record lands in the active user theme's own
// record; diverging from a read-only built-in, it lands in its own key
// instead, so a casual toggle survives relaunch without dirtying the
// built-in, and re-applying the theme resets it. A continuous control —
// the corner-radius slider, a color well tracking its panel — reports each
// tick with continuous:YES, which is what lets undo fold the gesture into
// one entry; the bare form is a discrete edit.
- (void)currentThemeDidChange;
- (void)currentThemeDidChangeContinuous:(BOOL)continuous;

// User-theme CRUD. Every mutation refuses a built-in identifier; names are
// deduped against every display name. addUserThemeWithRecord returns the
// minted id; duplicateThemeWithIdentifier resolves built-ins and user themes
// alike and returns the copy's id, nil for an unknown source. Removing the
// active theme applies the successor — nil, or one that names nothing, is
// vibe — and the caller requests VibeSettingsLiveEffectThemeApply as it
// would for any apply. Every path that can drop the last reference to a
// custom placeholder image sweeps the container's files itself.
- (NSString *)addUserThemeWithRecord:(NSDictionary<NSString *, id> *)record
                                name:(nullable NSString *)name;
- (nullable NSString *)duplicateThemeWithIdentifier:(NSString *)identifier;
- (void)removeUserThemeWithIdentifier:(NSString *)identifier
                        fallingBackTo:(nullable NSString *)successor;
- (void)renameUserThemeWithIdentifier:(NSString *)identifier toName:(NSString *)name;

- (BOOL)isPitchPanelShown;
- (void)setPitchPanelShown:(BOOL)shown;

- (BOOL)isPlaylistShown;
- (void)setPlaylistShown:(BOOL)shown;

// YES keeps the player window above every other app's windows
// (NSFloatingWindowLevel). View > Always on Top and Settings > General share
// this setting; VibeSettingsLiveEffectAlwaysOnTop is the shared post-write
// path that acts on it.
- (BOOL)alwaysOnTop;
- (void)setAlwaysOnTop:(BOOL)onTop;


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
// 2000. The stored choice the popup displays; what the player is told is
// effectiveCrossfadeMilliseconds, which VibeSettingsLiveEffectCrossfade
// pushes. Pause, seek and stop declicks never scale with it.
- (NSInteger)crossfadeMilliseconds;
- (void)setCrossfadeMilliseconds:(NSInteger)milliseconds;

// The crossfade the player is told: the declick minimum while bit-perfect
// output is on (two tracks summed is not bit-perfect), else the stored choice.
// The one push site reads this, never crossfadeMilliseconds.
- (NSInteger)effectiveCrossfadeMilliseconds;

// Settings > Playback > On track end. NO, the default, plays the next track
// in the playlist when one ends; YES parks on the finished track exactly as
// the end of the playlist does. It is enforced in one place — the successor
// prefetch, which is also the player's gapless arm point (MainPlayerController's
// successorPrefetchTrack) — so a writer must request
// VibeSettingsLiveEffectEndOfTrack to re-park or drop the handle.
- (BOOL)pauseAtTrackEnd;
- (void)setPauseAtTrackEnd:(BOOL)pause;

// Settings > General > Startup > Load last playlist on launch. NO, the
// default, starts empty; YES has the mac shell mirror the playlist to the
// container at quit and reopen it parked at launch (MainPlayerController). A
// writer must request VibeSettingsLiveEffectReopenLastPlaylist, which deletes
// the mirror when switched off.
- (BOOL)reopenLastPlaylist;
- (void)setReopenLastPlaylist:(BOOL)reopen;

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
// graph choice is read once at launch. When a graph exists, switching this off
// clears every active effect and withdraws its macOS menu and Q/W/E/R/T controls
// immediately; without one the controls remain absent until relaunch. iOS
// passes a hard NO and never consults this; see PlayerViewController.
// The stored choice, which the Playback pane's switch displays. Whether FX
// exist for the user is audioFXAllowed below, which bit-perfect output
// outranks.
- (BOOL)audioFXEnabled;
- (void)setAudioFXEnabled:(BOOL)enabled;

// Settings > General > Audio > Bit-perfect output, default NO. While on, the
// chain is pruned to the exact one — no FX (this outranks audioFXEnabled at
// every gate, and the next launch builds no FX graph), no varispeed, the
// crossfade at the declick minimum, the pitch fader gone — and each track's
// settlement sets the chosen device to the file's rate and word length.
// The shell only turns it on for an eligible device (OutputFormatRules.h):
// the General pane disables the switch
// otherwise, the Output menu grays ineligible devices out while it is on, and
// the device-vanished fallback turns it off. A writer requests
// VibeSettingsLiveEffectBitPerfect | FXControls | Crossfade.
- (BOOL)bitPerfectOutput;
- (void)setBitPerfectOutput:(BOOL)enabled;

// Optional exclusive access while bit-perfect output is on, default NO.
// The system output and virtual devices remain shared. Compiled-out builds
// always read NO, even if an earlier build stored YES. Writers request
// VibeSettingsLiveEffectBitPerfect; the FX and crossfade choices do not move.
- (BOOL)exclusiveOutput;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
- (void)setExclusiveOutput:(BOOL)enabled;
#endif

// The one answer to "do FX exist for the user": audioFXEnabled and not
// bitPerfectOutput. Every gate reads this — the launch-time graph choice,
// the FX menu's visibility and key equivalents, menu validation, the key
// monitor and the FXControls effect's clear — never audioFXEnabled.
- (BOOL)audioFXAllowed;

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
// (see Audio/Analysis/CLAUDE.md), which is not good enough to put in front of someone
// unasked, while a key the file already carries always shows.
- (BOOL)analyzeKey;
- (void)setAnalyzeKey:(BOOL)analyze;


// YES makes Convert to FLAC always run the save panel instead of writing the
// FLAC silently beside the source.
- (BOOL)convertAsksWhereToSave;
- (void)setConvertAsksWhereToSave:(BOOL)ask;

// YES lets a file with no art of its own show a cover image sitting beside it —
// cover.jpg and its cousins; see FolderArtResolver, which reads this. Default on,
// and it never overrides a file's own art. **Whoever writes it must then request
// VibeSettingsLiveEffectFolderArt**: the resolver caches this value, and that
// effect drops the cached copy — so a write without it is not observed at all.
// Reading a sibling file needs a folder grant, which is why Settings > Files holds both
// this and the grants. Folder art is macOS-only; iOS leaves AudioTrackArtwork's
// resolver handle nil and shows embedded art alone.
- (BOOL)useFolderArt;
- (void)setUseFolderArt:(BOOL)use;

// Binds an asynchronous picker to its original editable theme. The data
// provider is not called for a superseded pick. Caller persists through
// currentThemeDidChange and then requests the image field's live effect.
- (BOOL)setCurrentThemeImageForKey:(NSString *)key
                 themeIdentifier:(NSString *)identifier
                            data:(NSData * _Nullable (^)(void))data
                           error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
