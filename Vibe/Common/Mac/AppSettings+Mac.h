//
//  AppSettings+Mac.h
//  Vibe
//
//  The macOS half of AppSettings: every mac-only preference and the theme
//  store. Callers import it explicitly beside AppSettings.h.
//

#import "AppSettings.h"
#import "AppTheme.h"

// Nonnull by default, as in AppSettings.h (the device strings register @"").
NS_ASSUME_NONNULL_BEGIN

@class NSAppearance;


// The window's appearance setting: "" follows the OS, light and dark pin it.
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT     @""
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT       @"light"
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK        @"dark"

// The header's color wash: none, the art's dominant color (default), or the
// picked pair. Only the wash follows it; the art color still settles for the
// Dock icon and the album_art waveform theme.

#define SETTINGS_VALUE_WINDOW_TINT_MONO                     @"mono"
#define SETTINGS_VALUE_WINDOW_TINT_ARTWORK                  @"artwork"
#define SETTINGS_VALUE_WINDOW_TINT_CUSTOM                   @"custom"

// Key-label notation identifiers, never display names.
#define SETTINGS_VALUE_KEY_NOTATION_CAMELOT                 @"camelot"
#define SETTINGS_VALUE_KEY_NOTATION_MUSICAL                 @"musical"

// A drag on the waveform: drag_window (default) moves the window and only a
// stationary click seeks; seek scrubs.
#define SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW                 @"drag_window"
#define SETTINGS_VALUE_WAVEFORM_DRAG_SEEK                   @"seek"

// What dragging the album art out delivers: the audio file (default), its
// POSIX path, or the track's single-line name.
#define SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE               @"copy_file"
#define SETTINGS_VALUE_ARTWORK_DRAG_COPY_PATH               @"copy_path"
#define SETTINGS_VALUE_ARTWORK_DRAG_COPY_ARTIST_TITLE       @"copy_artist_title"

// The mac-only preset ladders the panes build their popups from; the getters
// snap any other stored value to the nearest preset.
FOUNDATION_EXPORT const NSInteger kVibeSkipBasePresets[];
FOUNDATION_EXPORT const size_t kVibeSkipBasePresetCount;
FOUNDATION_EXPORT const NSInteger kVibeUIUpdateHzCapPresets[];
FOUNDATION_EXPORT const size_t kVibeUIUpdateHzCapPresetCount;

static const double kVibeWaveformGainMaxDB = 12;

@interface AppSettings (Mac)

#pragma mark - macOS only

- (NSString *)audioOutputDeviceName;
- (void)setAudioOutputDeviceName:(NSString *)deviceName;

// The CoreAudio device UID, which survives duplicate names; the name above is
// the fallback.
- (NSString *)audioOutputDeviceUID;
- (void)setAudioOutputDeviceUID:(NSString *)deviceUID;

// The saved device's kAudioDevicePropertyModelUID. A class-compliant USB
// interface's UID is its port, so the model UID is what recognises it — and
// carries its modes — on a new port.
- (NSString *)audioOutputDeviceModelUID;
- (void)setAudioOutputDeviceModelUID:(NSString *)modelUID;

// "" (Auto, the default) tracks the OS; light and dark pin the main window.
// Deliberately outside the theme, which decides only its colors' mode.
- (NSString *)windowAppearanceStyle;
- (void)setWindowAppearanceStyle:(NSString *)name;

// The one answer every reader uses; nil tracks the OS. A single-mode theme's
// pin (AppTheme.requiredWindowAppearance) outranks the preview, which
// outranks the stored style.
- (nullable NSAppearance *)windowAppearance;

// The Appearance page's temporary light/dark preview. Never persisted, and
// writing windowAppearanceStyle clears it, so an explicit choice never lands
// under a stale preview. A writer requests
// VibeSettingsLiveEffectWindowAppearance.
- (nullable NSString *)windowAppearancePreviewStyle;
- (void)setWindowAppearancePreviewStyle:(nullable NSString *)name;

// A writer requests VibeSettingsLiveEffectTrafficLights.
- (BOOL)showTrafficLights;
- (void)setShowTrafficLights:(BOOL)show;


#pragma mark Themes

// Themed appearance fields have no accessors here: read currentTheme.

// The working theme every appearance consumer reads, materialized once and
// mutated in place. Main thread only.
- (AppTheme *)currentTheme;

// The named theme the working state derives from: a built-in identifier or a
// user theme's minted id, snapped to vibe when it names neither.
- (NSString *)activeThemeIdentifier;

// Built-ins first, then the user themes in creation order.
- (NSArray<NSString *> *)orderedThemeIdentifiers;

// Reset settings and delete custom themes and their unused images.
- (void)factoryReset;

// A user theme's stored name; the built-ins' localized names. nil for an
// identifier that names nothing.
- (nullable NSString *)displayNameForThemeIdentifier:(NSString *)identifier;

// The named theme's sanitized sparse record; vibe's (empty) for an unknown
// identifier.
- (NSDictionary<NSString *, id> *)recordForThemeIdentifier:(NSString *)identifier;

// Edits, renames and removals share fifty undo/redo entries; continuous edits
// coalesce. Applying a theme clears history. Images stay on disk while history
// can restore them. The caller requests ThemeApply.
@property (readonly, nonatomic) BOOL canUndoThemeEdit;
@property (readonly, nonatomic) BOOL canRedoThemeEdit;
@property (readonly, nonatomic) BOOL themeUndoRemovesTheme;
@property (readonly, nonatomic) BOOL themeRedoRemovesTheme;
@property (readonly, nonatomic) BOOL currentThemeIsModified;
- (void)undoThemeEdit;
- (void)redoThemeEdit;

// Store only: the caller requests VibeSettingsLiveEffectThemeApply.
- (void)applyThemeWithIdentifier:(NSString *)identifier;

// The one persist funnel, called after every currentTheme field edit. The
// working record lands in the active user theme, or for a built-in in the
// divergence key, which re-applying the theme clears. A continuous control
// (a slider, a tracking color well) passes continuous:YES so undo folds the
// gesture into one entry.
- (void)currentThemeDidChange;
- (void)currentThemeDidChangeContinuous:(BOOL)continuous;

// Every mutation refuses a built-in identifier; names are deduped against
// every display name. Duplicating the active theme copies its working record.
// duplicate answers nil for an unknown source. Removing the active theme
// activates the successor (vibe when it names nothing) and the caller requests
// VibeSettingsLiveEffectThemeApply. Each path sweeps orphaned images itself.
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

// A writer requests VibeSettingsLiveEffectAlwaysOnTop.
- (BOOL)alwaysOnTop;
- (void)setAlwaysOnTop:(BOOL)onTop;

// A writer requests VibeSettingsLiveEffectWindowLock.
- (BOOL)windowPositionLocked;
- (void)setWindowPositionLocked:(BOOL)locked;


// Normalized on read: an unknown value reads as drag_window.
- (NSString *)waveformDragBehavior;
- (void)setWaveformDragBehavior:(NSString *)behavior;

// Normalized on read: an unknown value reads as copy_file.
- (NSString *)artworkDragAction;
- (void)setArtworkDragAction:(NSString *)action;

// The pitch fader's range in percent: 8 or 16.
- (NSInteger)pitchRange;
- (void)setPitchRange:(NSInteger)range;

// NO hides the whole Convert feature: the Convert menu and the context items.
- (BOOL)convertEnabled;
- (void)setConvertEnabled:(BOOL)enabled;

// YES trashes the source once its FLAC is in place, on every conversion path.
- (BOOL)deleteOriginalAfterConvert;
- (void)setDeleteOriginalAfterConvert:(BOOL)deleteOriginal;

// The smallest skip's bar count; the others are twice and four times it. The
// tempo-unknown fallbacks (10/30/60s) do not scale with it.
- (NSInteger)skipBaseBars;
- (void)setSkipBaseBars:(NSInteger)bars;

// What the player is told: the declick minimum under bit-perfect output (two
// tracks summed is not bit-perfect), else the stored choice.
- (NSInteger)effectiveCrossfadeMilliseconds;

// The waveform level mapping (WaveformLevelMath.h): plain settings, not theme
// fields, because they suit a library's mastering and must survive a theme
// switch. Writers request VibeSettingsLiveEffectWaveformLevels. The gain
// getter answers the half-dB ladder.
- (BOOL)waveformNormalize;
- (void)setWaveformNormalize:(BOOL)normalize;
- (double)waveformGainDB;
- (void)setWaveformGainDB:(double)gainDB;

// YES mirrors the playlist at quit and reopens it parked at launch. A writer
// must request VibeSettingsLiveEffectReopenLastPlaylist, which deletes the
// mirror when switched off.
- (BOOL)reopenLastPlaylist;
- (void)setReopenLastPlaylist:(BOOL)reopen;

// The ceiling on the playback-UI tick rate, which otherwise scales with the
// playhead's on-screen speed (Util/UIUpdateMath.h).
- (NSInteger)uiUpdateHzCap;
- (void)setUiUpdateHzCap:(NSInteger)hz;

// Advanced testing override, default NO. Changes request BitPerfectApply.
- (BOOL)allowBitPerfectOnAnyDevice;
- (void)setAllowBitPerfectOnAnyDevice:(BOOL)allowed;

// While on: no FX, no varispeed, the crossfade at the declick minimum, and
// each track sets the device to the file's rate and word length.
//
// This and exclusiveOutput are remembered per device UID, surviving unplug.
// The plain accessors read the saved device's; System Output has no UID and
// is always off, so the device-vanished fallback needs no write. Off is
// stored as absence.
//
// The shell turns it on only for an eligible device (OutputFormatRules.h). A
// writer requests VibeSettingsLiveEffectBitPerfect | FXControls | Crossfade,
// and so does a change of saved device, since every reader moves with it.
- (BOOL)bitPerfectOutput;
- (void)setBitPerfectOutput:(BOOL)enabled;
// What a switch to that device hands the player with the device itself.
- (BOOL)bitPerfectOutputForDeviceUID:(nullable NSString *)deviceUID;
// For the same model on a new USB port. Never overwrites toUID's modes.
- (void)carryOutputModesFromDeviceUID:(NSString *)fromUID toDeviceUID:(NSString *)toUID;

// Exclusive access under bit-perfect output, per device like it. Reads NO
// when compiled out, whatever is stored. Writers request
// VibeSettingsLiveEffectBitPerfect.
- (BOOL)exclusiveOutput;
- (BOOL)exclusiveOutputForDeviceUID:(nullable NSString *)deviceUID;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
- (void)setExclusiveOutput:(BOOL)enabled;
#endif

// One choice for every device: a transport edge ramps ≤10 ms, or cuts leaving
// every sample untouched. A longer crossfade fades either way. Writers
// request VibeSettingsLiveEffectDeclick.
- (BOOL)declick;
- (void)setDeclick:(BOOL)declick;

// Volume control, default off: a volume slider in the player window, revealed
// on hover like the transport. `volume` is its position, 0..1, kept while the
// control is off. Allowed under bit-perfect output, whose report then says the
// volume is scaled. Writers request VibeSettingsLiveEffectVolume.
- (BOOL)volumeControl;
- (void)setVolumeControl:(BOOL)enabled;
- (double)volume;
- (void)setVolume:(double)volume;
// What the player is told: the stored volume while the control is on, full
// volume, which passes every sample untouched, otherwise.
- (double)effectiveVolume;

// audioFXEnabled and not bitPerfectOutput. Every UI gate reads this; only the
// player's output-mode rebuild takes the raw choice, beside bitPerfectOutput.
- (BOOL)audioFXAllowed;

// Not bitPerfectOutput, which hosts no varispeed for the fader to drive.
- (BOOL)pitchControlAllowed;

// NO skips key detection; same caching caveat as the shared analyzeBPM.
// Defaults off: detection is right about half the time on real dance music
// (Audio/Analysis/AGENTS.md).
- (BOOL)analyzeKey;
- (void)setAnalyzeKey:(BOOL)analyze;


- (BOOL)convertAsksWhereToSave;
- (void)setConvertAsksWhereToSave:(BOOL)ask;

// YES lets a file with no embedded art show the cover beside it. A writer
// MUST request VibeSettingsLiveEffectFolderArt: FolderArtResolver caches this
// value, so a write without it is never observed.
- (BOOL)useFolderArt;
- (void)setUseFolderArt:(BOOL)use;

// NO, without calling `data`, when `identifier` is no longer the active user
// theme. The caller then calls currentThemeDidChange and requests the field's
// live effect.
- (BOOL)setCurrentThemeImageForKey:(NSString *)key
                 themeIdentifier:(NSString *)identifier
                            data:(NSData * _Nullable (^)(void))data
                           error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
