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

// The crossfade slider in milliseconds: off is 10, the declick minimum, then
// tenths of a second up to three. The getter snaps any other stored value to
// the nearest step.
static const NSInteger kVibeCrossfadeOffMilliseconds = 10;
static const NSInteger kVibeCrossfadeStepMilliseconds = 100;
static const NSInteger kVibeCrossfadeMaxMilliseconds = 3000;

// The repeat mode's stable stored identifiers, never display names. The order
// a tap or ⌘R cycles the modes is VibeRepeatModeAfter's.
#define SETTINGS_VALUE_REPEAT_MODE_OFF      @"off"
#define SETTINGS_VALUE_REPEAT_MODE_ALL      @"all"
#define SETTINGS_VALUE_REPEAT_MODE_ONE      @"one"

// The folder-open order's stable stored identifiers, never display names.
#define SETTINGS_VALUE_FOLDER_OPEN_SORT_NAME            @"name"
#define SETTINGS_VALUE_FOLDER_OPEN_SORT_NEWEST_FIRST    @"newest_first"
#define SETTINGS_VALUE_FOLDER_OPEN_SORT_AS_RECEIVED     @"as_received"

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

// iOS draws two waveforms, the card's and the widget's. Each setting below
// is stored twice. `widget` picks the widget's copy, which counts only while
// the widget's style is its own. Under Match app a widget read answers the
// card's, as the widget draws the card's. A widget write always lands in the
// widget's copy. The widget is always dark, so its light colors are never
// read.
//
// Normalized on read: an unknown identifier snaps to mono.
- (NSString *)waveformThemeForWidget:(BOOL)widget;
- (void)setWaveformTheme:(NSString *)identifier forWidget:(BOOL)widget;

// The custom theme's played/unplayed pair per appearance, as #RRGGBB[AA] with
// the alpha the side's resting level. nil when unset or unparsable.
- (nullable VibeColor *)waveformCustomPlayedColorForDark:(BOOL)isDark widget:(BOOL)widget;
- (void)setWaveformCustomPlayedColor:(nullable VibeColor *)color forDark:(BOOL)isDark widget:(BOOL)widget;
- (nullable VibeColor *)waveformCustomUnplayedColorForDark:(BOOL)isDark widget:(BOOL)widget;
- (void)setWaveformCustomUnplayedColor:(nullable VibeColor *)color forDark:(BOOL)isDark widget:(BOOL)widget;

// 3-Band's palette. It is kept apart from waveformTheme, so a style switch
// keeps both choices. Normalized on read: an unknown identifier snaps to
// Rekord Bin.
- (NSString *)waveformBandThemeForWidget:(BOOL)widget;
- (void)setWaveformBandTheme:(NSString *)identifier forWidget:(BOOL)widget;

// Spectrum's palette, apart from the other two for the same reason.
// Normalized on read: an unknown identifier snaps to RGB.
- (NSString *)waveformSpectrumPaletteForWidget:(BOOL)widget;
- (void)setWaveformSpectrumPalette:(NSString *)identifier forWidget:(BOOL)widget;

// Spectrum's coloring. Normalized on read: an unknown identifier snaps to
// Sections.
- (NSString *)waveformSpectrumColoringForWidget:(BOOL)widget;
- (void)setWaveformSpectrumColoring:(NSString *)identifier forWidget:(BOOL)widget;

// The custom palette's bands per appearance, which 3-Band's and Spectrum's
// Custom share. band is 0 for low, 1 for mid and 2 for high. Stored opaque as
// #RRGGBB, because 3-Band's layers stack. nil when unset or unparsable.
- (nullable VibeColor *)waveformCustomBandColor:(NSUInteger)band forDark:(BOOL)isDark widget:(BOOL)widget;
- (void)setWaveformCustomBandColor:(nullable VibeColor *)color band:(NSUInteger)band
                           forDark:(BOOL)isDark widget:(BOOL)widget;

// Whether the playhead is a line over a waveform drawn wholly as played. nil
// until the user chooses, and deliberately unregistered: the default is the
// style's (WaveformRendererRegistry.drawsPlayheadLineForIdentifier:chosen:).
- (nullable NSNumber *)waveformPlayheadLineForWidget:(BOOL)widget;
- (void)setWaveformPlayheadLine:(BOOL)line forWidget:(BOOL)widget;

// The mac theme's waveformCentered: NO grounds the bars on a baseline.
- (BOOL)waveformCenteredForWidget:(BOOL)widget;
- (void)setWaveformCentered:(BOOL)centered forWidget:(BOOL)widget;

// Posted on main after a settings screen writes any display setting, the
// waveform style included; the keep-alive card is the receiver. Every writer
// ends on VibeNotifyDisplaySettingsChanged, never a hand-composed post. The
// time label's own tap repaints the pages itself and does not post.
extern NSNotificationName const VibeDisplaySettingsDidChangeNotification;
void VibeNotifyDisplaySettingsChanged(void);

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
// pushes it into Playlist.pauseAtTrackEnd, which enforces it (root AGENTS.md).
// A writer must push and re-park. Otherwise a mid-track switch to Pause leaves
// an armed gapless splice that advances anyway.
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

// Settings > Playback > Audio effects, both platforms, default YES:
// whether the DJ FX segment is in the render. The store never applies it:
// the mac writer requests its live effect, the iOS writer calls
// PlaybackController.applyFXSetting. On the mac audioFXAllowed
// (Mac/AppSettings+Mac.h) folds in bit-perfect output, which outranks this.
- (BOOL)audioFXEnabled;
- (void)setAudioFXEnabled:(BOOL)enabled;

// Settings > Playback > Detect BPM automatically, both platforms, default
// YES. NO skips tempo detection. A file decoded while off is decoded again
// when next asked for with it on, since its entry holds no tempo. Each shell
// lists the tempo's observer in its analysis provider, so the loader never
// reads this. Key detection is macOS-only (analyzeKey, Mac/AppSettings+Mac.h).
- (BOOL)analyzeBPM;
- (void)setAnalyzeBPM:(BOOL)analyze;

// Normalized on read: an unknown identifier reads as Name. Each shell reads it
// at open time and hands it to the walk; a change never reorders the
// playlist on screen.
- (VibeFolderOpenSort)folderOpenSort;
- (void)setFolderOpenSort:(VibeFolderOpenSort)sort;

#pragma mark Player display

// Display choices use each platform's shipped keys. The store applies none.
// A mac writer requests VibeSettingsLiveEffectTrackDisplay. An iOS writer
// ends on VibeNotifyDisplaySettingsChanged.
//
// NO (default) shows the duration on the right, YES the minus-prefixed
// remaining time.
@property (nonatomic) BOOL showRemainingTime;
// The codec line, default YES. On the mac it also gates the BPM/key line,
// which has its own switches; on iOS the tempo follows the codec on one line.
@property (nonatomic) BOOL showFileInfo;
// The shuffle and repeat buttons beside the transport, default YES. Only iOS
// draws them: hidden, both modes are off and CarPlay offers neither
// (PlaybackController.pushTransportModes).
@property (nonatomic) BOOL showShuffleRepeat;

// Whether the bundled vibe-theme.mp3 is spent. The mac parks it on every launch
// that restores nothing, and spends it on the user's first play or open. iOS
// copies it into Documents on the first launch and spends it then. State, not
// a preference: cleared only by the mac's factoryReset.
@property (nonatomic) BOOL welcomeTrackSpent;

@end

NS_ASSUME_NONNULL_END
