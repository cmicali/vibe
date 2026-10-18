//
//  AppSettings+Mac.h
//  Vibe
//
//  The macOS half of AppSettings: every mac-only preference. Callers import it
//  explicitly beside AppSettings.h.
//

#import "AppSettings.h"
// The theme store, which most mac readers use too.
#import "AppSettings+Themes.h"

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

// The Dock tile while a track with artwork plays: its cover (default), or the
// app icon throughout.
#define SETTINGS_VALUE_DOCK_ICON_ALBUM_ART                  @"album_art"
#define SETTINGS_VALUE_DOCK_ICON_APP_ICON                   @"app_icon"

// The volume slider's place. Top right swaps with the corner readouts on
// hover (MainWindow/LAYOUT.md).
#define SETTINGS_VALUE_VOLUME_LOCATION_BOTTOM               @"bottom"
#define SETTINGS_VALUE_VOLUME_LOCATION_TOP_RIGHT            @"top_right"
// When the volume slider shows.
#define SETTINGS_VALUE_VOLUME_VISIBILITY_ALWAYS             @"always"
#define SETTINGS_VALUE_VOLUME_VISIBILITY_HOVER_CLOSE        @"hover_close"
#define SETTINGS_VALUE_VOLUME_VISIBILITY_HOVER_EXACT        @"hover_exact"

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
// The interval Automatically check for updates writes when turned on: daily,
// Sparkle's own first-launch schedule.
static const NSTimeInterval kVibeUpdateCheckIntervalDefault = 24 * 3600;

static const double kVibeWaveformGainMaxDB = 12;

@interface AppSettings (Mac)

#pragma mark - macOS only

- (void)applicationDidFinishLaunching;

// Settings > Advanced > Reset. Preserves custom themes; bookmarks, stats and
// window frames live elsewhere. Clears the store only: the caller owns the
// running-app effects.
- (BOOL)allSettingsAtDefaults;
// What factoryReset would leave: settings at their defaults, no user themes,
// and the welcome track not yet spent. Restore Defaults… enables on NO.
- (BOOL)atFactoryDefaults;
- (void)resetToDefaults;
// Reset settings and delete custom themes and their unused images.
- (void)factoryReset;

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

#pragma mark Player display

// What the window shows, whatever the theme, with showRemainingTime and
// showFileInfo in AppSettings.h. Every header readout's writer requests
// VibeSettingsLiveEffectTrackDisplay.
@property (nonatomic) BOOL showTimeLabels;
@property (nonatomic) BOOL showStatusIcons;     // the FX and bit-perfect symbols
@property (nonatomic) BOOL showBPM;
@property (nonatomic) BOOL showKey;
@property (nonatomic, copy) NSString *keyNotation;  // camelot/musical
@property (nonatomic) BOOL keyColorsEnabled;
// The column writers request VibeSettingsLiveEffectPlaylistAppearance.
@property (nonatomic) BOOL showPlaylistNumberColumn;
@property (nonatomic) BOOL showPlaylistArtworkColumn;
@property (nonatomic) BOOL showPlaylistDurationColumn;
// album_art/app_icon. A writer requests VibeSettingsLiveEffectAppIcon.
@property (nonatomic, copy) NSString *dockIcon;


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

// AudioFileHandle.appleMPEGDecoder's stored value, default NO (dr_mp3).
// Changes request VibeSettingsLiveEffectMP3Decoder.
- (BOOL)appleMPEGDecoder;
- (void)setAppleMPEGDecoder:(BOOL)apple;

#if VIBE_DIRECT_DISTRIBUTION
// Whether the updater also offers the feed's beta channel. Compiled out of
// the Mac App Store build. Default YES in a beta build (VIBE_BETA_DEBUG),
// NO in a stable one. A beta build stores it at launch, so a stable update
// keeps a tester on betas. Read at each check, so a change needs no live effect.
- (BOOL)receiveBetaUpdates;
- (void)setReceiveBetaUpdates:(BOOL)receive;
#endif

// The Keyboard Shortcuts pane's remaps, sparse over the defaults: absent
// means every default. Read per keypress by the key monitor. Writers request
// VibeSettingsLiveEffectShortcuts.
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *shortcutOverrides;

// While on: no FX, no varispeed, the crossfade at the declick minimum, and
// each track requests the file's rate and a suitable device sample format.
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

// Exclusive access under bit-perfect output, per device like it. Writers
// request VibeSettingsLiveEffectBitPerfect.
- (BOOL)exclusiveOutput;
- (BOOL)exclusiveOutputForDeviceUID:(nullable NSString *)deviceUID;
- (void)setExclusiveOutput:(BOOL)enabled;

// One choice for every device: a transport edge ramps ≤10 ms, or cuts leaving
// every sample untouched. A longer crossfade fades either way. Writers
// request VibeSettingsLiveEffectDeclick.
- (BOOL)declick;
- (void)setDeclick:(BOOL)declick;

// Volume control, default off: a volume slider in the player window. `volume`
// is its position, 0..1, kept while the control is off. The switch requests
// VibeSettingsLiveEffectVolume. The slider's own drag pushes the player and
// its percentage directly.
- (BOOL)volumeControl;
- (void)setVolumeControl:(BOOL)enabled;
- (double)volume;
- (void)setVolume:(double)volume;
// What the player is told: the stored volume while the control is on, full
// volume, which passes every sample untouched, otherwise.
- (double)effectiveVolume;
// Where the slider sits (top_right, the default, or bottom), when it shows
// (always, hover_close, the default, or hover_exact), and whether "Vol" and
// the percentage flank it. Writers request VibeSettingsLiveEffectVolume.
- (NSString *)volumeLocation;
- (void)setVolumeLocation:(NSString *)location;
- (NSString *)volumeVisibility;
- (void)setVolumeVisibility:(NSString *)visibility;
- (BOOL)showVolumeLabels;
- (void)setShowVolumeLabels:(BOOL)show;

// audioFXEnabled and not bitPerfectOutput. Every UI gate reads this; only the
// player's output-mode rebuild takes the raw choice, beside bitPerfectOutput.
- (BOOL)audioFXAllowed;

// Not bitPerfectOutput, which hosts no varispeed for the fader to drive.
- (BOOL)pitchControlAllowed;

// NO skips key detection; re-enabling re-decodes as the shared analyzeBPM does.
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

@end

NS_ASSUME_NONNULL_END
