//
//  AppTheme.h
//  Vibe
//
// One theme: every appearance choice the theme system governs, as typed
// accessors over a sparse record. A record stores only values that differ
// from the defaults — today's hardcoded look — so the built-in Vibe theme is
// the empty record and cannot drift from the factory appearance. All
// sanitization lives here: initWithRecord: and every setter run the same
// clamps, so a JSON import, a stored record and a UI edit are held to the
// same rules. Records are Foundation plist/JSON values throughout
// (strings, numbers, bools), colors as #RRGGBB[AA] hex.
//
// macOS-only by directory: themes govern the window, playlist and menu
// surfaces that exist only there. iOS keeps its own loose settings.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

// The built-in themes' stable identifiers — never display names, which are
// localized. User themes are identified by minted UUID strings instead, so
// the two namespaces cannot collide.
FOUNDATION_EXPORT NSString *const kVibeThemeIdentifierVibe;

// The theme's color mode. dual — the factory default, and what the built-in
// Vibe theme is — keeps a separate color set per appearance and follows
// whatever appearance the window has. single keeps ONE color per field and
// always uses it, whatever the system or Vibe's own appearance setting says;
// the window's chrome still follows the appearance, only the theme's colors
// stop caring. The art-keyed transport pairs (kVibeThemeColorPlaylistButton)
// are the exception.
#define SETTINGS_VALUE_THEME_MODE_SINGLE                    @"single"
#define SETTINGS_VALUE_THEME_MODE_DUAL                      @"dual"

// The background styles' stable identifiers, shared by the window and the
// playlist: glass, the default, is the translucent look as shipped; solid
// covers it with the surface's color pair, whose alpha is the cover's
// opacity; clear drops the surface's own pane so the window's Clear glass
// backdrop — what a transparent placeholder shows through the art — is the
// whole look. On the playlist, solid and clear both remove the behind-window
// blur.
#define SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS              @"glass"
#define SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID              @"solid"
#define SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR              @"clear"

// What the Dock tile shows while a track with artwork plays: album_art, the
// default, composes the playing track's cover into the icon grid; app_icon
// leaves the app icon — the bundle's, or the theme's custom one — up
// throughout. The About surfaces and the app switcher always show the app
// icon, whichever this says.
#define SETTINGS_VALUE_DOCK_ICON_ALBUM_ART                  @"album_art"
#define SETTINGS_VALUE_DOCK_ICON_APP_ICON                   @"app_icon"

// The transport buttons' factory glyphs, the defaults the theme's four glyph
// fields carry. The pause glyph pairs with the play one: the editor writes
// both from one pick (SettingsRules.h's pair table), a JSON can set either.
#define kVibeThemePlaylistButtonGlyphDefault  @"list.bullet"
#define kVibeThemePlayButtonGlyphDefault      @"play.fill"
#define kVibeThemePauseButtonGlyphDefault     @"pause.fill"
#define kVibeThemeNextButtonGlyphDefault      @"forward.end.fill"

// The corner-radius clamp's ceiling. A macro rather than an exported const
// because the header panel's right bleed is a compile-time frame sized to it
// — a static frame that must stay valid for every legal radius rather than
// follow the live value.
#define kVibeThemeCornerRadiusMax ((CGFloat)36)
// The standard window radius — what a theme without a custom radius draws,
// and the editor's slider detent. The window is borderless and draws its own
// shape, so the system's radius is this constant rather than anything AppKit
// vends; it follows macOS 26's window corners.
#define kVibeThemeCornerRadiusDefault ((CGFloat)16)

#define kVibeThemeWaveformBarDensityMin 0.5
#define kVibeThemeWaveformBarDensityMax 4.0
#define kVibeThemeWaveformBarDensityDefault 1.0

// The font slots' factory sizes — the point size each slot draws at under
// the Vibe theme, the defaults the field rows carry.
#define kVibeThemeTitleFontBaseSize     ((CGFloat)23)
#define kVibeThemeArtistFontBaseSize   ((CGFloat)16)
#define kVibeThemeInfoFontBaseSize     ((CGFloat)13)
#define kVibeThemePlaylistFontBaseSize ((CGFloat)14)
#define kVibeThemePlaylistDurationFontBaseSize ((CGFloat)12)

// The five themed font slots, one spelling shared by the theme's per-slot
// accessors, Fonts' slot storage and the editor's font panel. None is
// deliberately zero, so a zero-filled ivar or an unset control tag reads as
// no slot, never as the title.
typedef NS_ENUM(NSInteger, VibeFontSlot) {
    VibeFontSlotNone = 0,
    VibeFontSlotTitle,
    VibeFontSlotArtist,
    VibeFontSlotInfo,
    VibeFontSlotPlaylist,
    VibeFontSlotPlaylistDuration,
};
// Array bound for per-slot storage indexed by VibeFontSlot (entry 0 unused).
#define kVibeFontSlotCount 6

// Keys a theme JSON carries beside the field overrides. The name travels on
// export/import; a record's id never leaves the store — export strips it,
// import mints a fresh one. (The JSON's version key is the writer's literal;
// the reader takes any record the gate accepts.)
FOUNDATION_EXPORT NSString *const kVibeThemeRecordNameKey;
FOUNDATION_EXPORT NSString *const kVibeThemeRecordIdentifierKey;

// The color pairs' base names — each record key less its Dark/Light suffix —
// the keys colorForBase:dark: and its siblings take.
FOUNDATION_EXPORT NSString *const kVibeThemeColorWaveformPlayed;
FOUNDATION_EXPORT NSString *const kVibeThemeColorWaveformUnplayed;
FOUNDATION_EXPORT NSString *const kVibeThemeColorWindowTint;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistTint;
FOUNDATION_EXPORT NSString *const kVibeThemeColorWindowBackground;
FOUNDATION_EXPORT NSString *const kVibeThemeColorTitle;
FOUNDATION_EXPORT NSString *const kVibeThemeColorArtist;
FOUNDATION_EXPORT NSString *const kVibeThemeColorInfo;
FOUNDATION_EXPORT NSString *const kVibeThemeColorTime;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistBackground;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistPlayingRow;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistSelectedRow;
// The three transport buttons' glyph colors, alpha included: the picked
// color is the button's resting color, and its hover and disabled states
// derive from it by the factory ratios (SymbolButton). Unset draws white at
// rest strength over dark artwork and black over light. These pairs are
// keyed by the art UNDER the buttons, not the appearance, and are the one
// exception to single mode: both sides stay live under it.
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistButton;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlayButton;
FOUNDATION_EXPORT NSString *const kVibeThemeColorNextButton;
// The playlist's four text columns, each behind its own switch
// (playlistColorEnabledForBase:). Off — the default — the column draws the
// label pair it always drew: the title column the title pair, the number,
// artist and duration columns the artist pair. On, it draws its own pair,
// an unset side falling back to that same label pair; the pair is kept
// while the switch is off, so toggling round-trips a pick.
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistNumber;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistTitle;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistArtist;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistDuration;

// The image fields' record keys — every field whose value names a FILE: ""
// (the default) is the slot's factory image; "custom:<sha1>.<ext>" an image
// the user picked, copied into the app container; "bundled:<name>.<ext>" an
// image a built-in theme ships in Resources/Themes/. One shape, one store,
// one archive form for all eleven: the no-artwork placeholder pair, the app
// icon, and the transport buttons' custom image pairs (the play button has
// a pair per state). The keys are the accessor names of the record and are
// persisted; never renamed.
FOUNDATION_EXPORT NSString *const kVibeThemeImageDefaultArtworkDark;
FOUNDATION_EXPORT NSString *const kVibeThemeImageDefaultArtworkLight;
FOUNDATION_EXPORT NSString *const kVibeThemeImageAppIcon;
// A transport button's images come as a pair like its colors — Dark over
// dark artwork, Light over light, art-keyed like them. An unset side draws
// the other side's image before falling back to the glyph, so one picked
// image dresses both.
FOUNDATION_EXPORT NSString *const kVibeThemeImagePlaylistButtonDark;
FOUNDATION_EXPORT NSString *const kVibeThemeImagePlaylistButtonLight;
FOUNDATION_EXPORT NSString *const kVibeThemeImagePlayButtonDark;
FOUNDATION_EXPORT NSString *const kVibeThemeImagePlayButtonLight;
FOUNDATION_EXPORT NSString *const kVibeThemeImagePauseButtonDark;
FOUNDATION_EXPORT NSString *const kVibeThemeImagePauseButtonLight;
FOUNDATION_EXPORT NSString *const kVibeThemeImageNextButtonDark;
FOUNDATION_EXPORT NSString *const kVibeThemeImageNextButtonLight;

@interface AppTheme : NSObject

+ (NSArray<NSString *> *)builtInThemeIdentifiers;
+ (BOOL)isBuiltInIdentifier:(nullable NSString *)identifier;

// The built-in's sparse record: empty for vibe, its overrides for the rest.
// Empty for an identifier that names no built-in — callers gate on
// isBuiltInIdentifier:.
+ (NSDictionary<NSString *, id> *)builtInRecordForIdentifier:(NSString *)identifier;

// The built-in's English display name, from its JSON's name key.
// AppSettings overlays the ThemeNames catalog for the localized form.
+ (nullable NSString *)builtInNameForIdentifier:(NSString *)identifier;

#pragma mark Images

// The image fields' keys (kVibeThemeImage*), in the editor's order — what
// the archive, the sweep and the editor's previews walk.
+ (NSArray<NSString *> *)imageFieldKeys;

// Never nil: the image a reference resolves to — the container image a
// custom: names, the Resources/Themes image a bundled: names, or the factory
// record image for "", an unknown name, or a missing file. Cached for the
// app's lifetime; custom references are content-hashed, so a changed image
// is a new key, and a bundled image is immutable per build. The factory
// fallback is the no-artwork placeholder's; the other slots ask
// customImageForKey: below, which answers nil for anything but a present
// custom or bundled image, so their factory is the glyph or the bundle icon.
+ (NSImage *)imageForReference:(nullable NSString *)reference;

// YES when the reference names an image that is not there: a container file
// that has gone, or a bundled name this build does not ship. "" is the
// factory image and is never missing, nor is a malformed value, which the
// sanitizer has already dropped. imageForReference: falls back for every one
// of these, so this is the only way to tell "deliberately the default" apart
// from "the chosen image is gone".
+ (BOOL)referenceIsMissing:(nullable NSString *)reference;

// Validates (JPEG or PNG, square, within pixel and byte caps), copies into
// the app container, and returns the record value ("custom:<sha1>.<ext>"),
// or nil with the reason. The bytes are stored as-is, never re-encoded.
+ (nullable NSString *)storeCustomImageData:(NSData *)data
                                      error:(NSError *_Nullable *_Nullable)error;

// The store's reverse: content-hash naming shares one file between every
// record referencing the same image, so deletion is a reference sweep rather
// than something paired with any one edit. Deletes every container image no
// record in `records` names — the caller (AppSettings.sweepUnreferencedThemeImages)
// passes every record that can hold a reference, dormant light halves
// included, since records carry every image key whatever the mode.
+ (void)removeCustomImageFilesUnreferencedByRecords:(NSArray<NSDictionary *> *)records;

#pragma mark Names, migration and JSON

// A usable theme name: trimmed, length-capped, the fallback when empty, and
// suffixed " 2", " 3", … past any name already in use.
+ (NSString *)dedupedThemeName:(nullable NSString *)candidate
                      fallback:(NSString *)fallback
                 existingNames:(NSArray<NSString *> *)existingNames;

// The one-time migration decision: the record to store as the migrated user
// theme, or nil to store nothing. legacyValues holds the raw stored values of
// the pre-theme loose settings keyed by their AppTheme field names; a value
// set that sanitizes to the defaults — an untouched install — answers nil.
+ (nullable NSDictionary<NSString *, id> *)migratedRecordFromLegacyValues:
        (NSDictionary<NSString *, id> *)legacyValues;

// A theme JSON, both ways. The file form is nested: version first, then
// name, then one object per editor section — window, player, info, waveform,
// playlist — holding that section's fields under section-local keys.
// recordFromJSONData caps the input size, requires a JSON object, reports the
// name it carried (nil when absent), and returns the sanitized sparse FLAT
// record — an empty record is a valid theme that looks like the defaults.
// JSONDataForRecord composes version + name + the grouped fields, pretty-
// printed with sorted keys inside each group. The id key never travels:
// export strips it, import mints a fresh one.
+ (nullable NSDictionary<NSString *, id> *)recordFromJSONData:(NSData *)data
                                                         name:(NSString *_Nullable *_Nullable)outName
                                                        error:(NSError **)error;
+ (nullable NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                                  name:(NSString *)name;

// Sanitized: unknown keys are dropped (a newer build's fields import as the
// defaults), malformed values are dropped, identifiers snap to their ladders,
// numbers clamp. nil builds the defaults — the Vibe look.
- (instancetype)initWithRecord:(nullable NSDictionary<NSString *, id> *)record;

// The gate as a function: the sparse record initWithRecord: would hold for
// this input. What the store and the JSON paths run a raw record through.
+ (NSDictionary<NSString *, id> *)sanitizedRecord:(nullable NSDictionary<NSString *, id> *)record;

// Repopulates every field from the record — applying a theme in place, so
// holders of the object see the switch.
- (void)replaceWithRecord:(nullable NSDictionary<NSString *, id> *)record;

// The sparse record: only fields differing from the defaults. This is the
// stored and exported form.
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

#pragma mark Fields

// Setters sanitize exactly like initWithRecord:, so the UI cannot store what
// a file load would refuse.

@property (nonatomic, copy) NSString *waveformStyle;        // WaveformRendererRegistry identifier
@property (nonatomic, copy) NSString *mode;                 // single/dual color sets
@property (readonly, nonatomic) BOOL isSingleMode;
@property (nonatomic, copy) NSString *waveformTheme;        // mono/orange/album_art/custom
@property (nonatomic) BOOL waveformGradient;                // NO draws flat bars, no vertical ramp
@property (nonatomic) double waveformBarDensity;            // multiplier of the style's designed count
@property (nonatomic, copy) NSString *windowTint;           // mono/artwork/custom
@property (nonatomic, copy) NSString *playlistTint;         // mono/artwork/custom; snaps to mono, the factory playlist wash
@property (nonatomic, copy) NSString *windowBackgroundStyle; // glass/solid
@property (nonatomic, copy) NSString *playlistBackgroundStyle; // glass/solid
// The radius the slider holds, clamped [0, kVibeThemeCornerRadiusMax], and
// whether the window draws it: off — the default — draws the standard radius
// (kVibeThemeCornerRadiusDefault) whatever the slider says, on draws the
// slider's value. A record naming a radius but not the switch reads as
// custom — the switch postdates the radius, so a stored or exported theme
// from before it keeps the shape it chose. resolvedWindowCornerRadius is
// the one the window consumers read.
@property (nonatomic) CGFloat windowCornerRadius;
@property (nonatomic) BOOL customCornerRadius;
@property (readonly, nonatomic) CGFloat resolvedWindowCornerRadius;
@property (nonatomic, copy) NSString *dockIcon;             // album_art/app_icon
// Whether the Dock's album art and a custom app icon are shaped the way
// macOS shapes an app icon — composed onto the icon grid, rounded and
// inset — or shown as the picture they are. YES, the default, is the look
// the Dock has always had.
@property (nonatomic) BOOL appIconShape;
// The darkening gradient over the album art's lower half, behind the
// transport buttons. NO leaves the art bare under them.
@property (nonatomic) BOOL buttonGradient;
@property (nonatomic) BOOL showTransportButtons;
// The transport buttons' SF Symbol names. Trimmed to the symbol-name shape
// (lowercase letters, digits and dots); a name this macOS has no symbol for
// draws the factory glyph, the way an uninstalled font face falls back — so
// a JSON may name any symbol without the record needing to know the
// catalog. A custom image, when the button's image field names one, wins
// over the glyph.
@property (nonatomic, copy) NSString *playlistButtonGlyph;
@property (nonatomic, copy) NSString *playButtonGlyph;
@property (nonatomic, copy) NSString *pauseButtonGlyph;
@property (nonatomic, copy) NSString *nextButtonGlyph;
@property (nonatomic) BOOL showFileInfo;
@property (nonatomic) BOOL showStatusIcons;
@property (nonatomic) BOOL showTimeLabels;
@property (nonatomic) BOOL showRemainingTime;
@property (nonatomic) BOOL showBPM;
@property (nonatomic) BOOL showKey;
@property (nonatomic) BOOL showPlaylistArtworkColumn;             // the playlist's art column
@property (nonatomic) BOOL showPlaylistDurationColumn;            // the playlist's length column
@property (nonatomic) BOOL keyColorsEnabled;
@property (nonatomic, copy) NSString *keyNotation;          // camelot/musical

// The five font slots. An empty face means the built-in font — Fonts owns
// what that resolves to, and resolves an uninstalled face with its never-nil
// fallback, so faces are not validated here. The size is the point size the
// slot draws at; the clamps are narrow because the frames the labels sit in
// are fixed. The slot-indexed accessors are the same fields by VibeFontSlot,
// for callers that walk the slots rather than name them; None names no
// field, so it reads as the empty face at size 0 and a write to it is dropped.
- (NSString *)fontFaceForSlot:(VibeFontSlot)slot;
- (CGFloat)fontSizeForSlot:(VibeFontSlot)slot;
- (void)setFontFace:(NSString *)face size:(CGFloat)size forSlot:(VibeFontSlot)slot;
@property (nonatomic, copy) NSString *titleFontFace;
@property (nonatomic) CGFloat titleFontSize;                 // clamped [20, 26]
@property (nonatomic, copy) NSString *artistFontFace;
@property (nonatomic) CGFloat artistFontSize;      // clamped [12, 20]
@property (nonatomic, copy) NSString *infoFontFace;
@property (nonatomic) CGFloat infoFontSize;                 // clamped [10, 15]
@property (nonatomic, copy) NSString *playlistFontFace;
@property (nonatomic) CGFloat playlistFontSize;             // clamped [11, 16]
@property (nonatomic, copy) NSString *playlistDurationFontFace;
@property (nonatomic) CGFloat playlistDurationFontSize;     // clamped [10, 14]

// The image fields by key (kVibeThemeImage*): the reference as stored, and
// the write behind every picker. The no-artwork placeholder is the one
// paired field, one per appearance like every color pair, and single mode
// reads and writes its dark slot from either side — the color pairs' rule —
// while the light half lies dormant, so a mode flip round-trips.
// Coupled editor choices: selecting a glyph clears every image it replaces,
// and Play also selects its paired Pause glyph.
+ (NSArray<NSString *> *)imageKeysForButton:(NSString *)key;
- (void)setGlyph:(NSString *)glyph forButtonImageKey:(NSString *)key;

- (NSString *)imageReferenceForKey:(NSString *)key;
- (void)setImageReference:(NSString *)reference forKey:(NSString *)key;
// The image a slot's reference resolves to when it names a present custom or
// bundled image, else nil — the app icon and the buttons fall back to their
// own factory (the bundle's icon, the glyph), never to the record image.
- (nullable NSImage *)customImageForKey:(NSString *)key;
// A transport button slot's picture for the art under it: its own, else the
// other side of its Dark/Light pair, so one picked image dresses both; nil
// when neither side has one, which is the glyph's cue.
- (nullable NSImage *)buttonImageForKey:(NSString *)key;
// This theme's resolved placeholder as ONE image: when the sides differ, a
// cached dynamic wrapper drawing whichever the current drawing appearance
// asks for — the dynamic-color pattern for pixels — so consumers need no
// dark flag and an appearance flip re-resolves by itself.
@property (readonly, nonatomic) NSImage *resolvedDefaultArtworkImage;

// Per-appearance color pairs — one color per appearance, like every stored
// color pair before them. nil means unset: the consumer draws today's
// default, stated beside where it was hardcoded. Alpha is meaningful
// throughout (a fill's strength, the solid background's opacity). Each pair
// is keyed by its base name (kVibeThemeColor*, above) for callers that walk
// the pairs — the editor's wells; the typed accessors below are the same
// slots by name.
- (nullable VibeColor *)colorForBase:(NSString *)base dark:(BOOL)isDark;
- (void)setColor:(nullable VibeColor *)color forBase:(NSString *)base dark:(BOOL)isDark;
// The pair pinned to one side, for the editor's per-side wells: the override,
// or what an unset slot draws as — the label pairs their semantic fallback
// resolved under that side's appearance (the dynamic fallback would resolve
// under the pane's own appearance and show the wrong side's color in the
// other side's well), every other pair the constant its surface paints (the
// solid cover, the neutral tint wash, the neutral row fill, Mono's resting
// levels). One home, so the surface an unset pair paints, the well that
// displays it and the seed a popup writes when it reveals the wells cannot
// disagree. A style or tint choice that does not consume the pair (glass,
// artwork) never reads it.
- (VibeColor *)displayColorForBase:(NSString *)base dark:(BOOL)isDark;
- (nullable VibeColor *)waveformPlayedColorForDark:(BOOL)isDark;
- (void)setWaveformPlayedColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)waveformUnplayedColorForDark:(BOOL)isDark;
- (void)setWaveformUnplayedColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)windowTintColorForDark:(BOOL)isDark;
- (void)setWindowTintColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)playlistTintColorForDark:(BOOL)isDark;
- (void)setPlaylistTintColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)windowBackgroundColorForDark:(BOOL)isDark;
- (void)setWindowBackgroundColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)titleColorForDark:(BOOL)isDark;
- (void)setTitleColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)artistColorForDark:(BOOL)isDark;
- (void)setArtistColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)infoColorForDark:(BOOL)isDark;
- (void)setInfoColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)timeColorForDark:(BOOL)isDark;
- (void)setTimeColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)playlistBackgroundColorForDark:(BOOL)isDark;
- (void)setPlaylistBackgroundColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)playlistPlayingRowColorForDark:(BOOL)isDark;
- (void)setPlaylistPlayingRowColor:(nullable VibeColor *)color forDark:(BOOL)isDark;
- (nullable VibeColor *)playlistSelectedRowColorForDark:(BOOL)isDark;
- (void)setPlaylistSelectedRowColor:(nullable VibeColor *)color forDark:(BOOL)isDark;


// The appearance a single-mode theme demands, or nil when the appearance
// setting should rule. Single mode is one constant look with no consideration
// of light or dark at all: the window pins to the dark appearance — the app's
// native look — so materials and unset defaults stop following the OS and the
// setting, and every color the theme sets is literal. A light background with
// unset label colors therefore keeps the dark defaults' white text: set the
// labels too; single mode never second-guesses the palette.
- (nullable NSAppearance *)requiredWindowAppearance;

// The four label colors resolved over their semantic fallbacks — title over
// labelColor, artist and time over secondaryLabelColor, info over
// tertiaryLabelColor — spelled once, so the header, the playlist, the corner
// readouts and the editor's wells cannot disagree about a slot's fallback.
// Each is one dynamic color: a nil override resolves to the fallback in the
// drawing appearance. The pair is captured at call time, so a theme change
// means rebuilding whatever holds the color — an appearance flip re-resolves
// by itself.
- (VibeColor *)resolvedTitleColor;
- (VibeColor *)resolvedArtistColor;
- (VibeColor *)resolvedInfoColor;
- (VibeColor *)resolvedTimeColor;

// The playlist columns' switches and resolution, by the four
// kVibeThemeColorPlaylist* text bases: the column's own pair when its switch
// is on, else the label pair it inherits — one dynamic color either way,
// captured like the four above.
- (BOOL)playlistColorEnabledForBase:(NSString *)base;
- (void)setPlaylistColorEnabled:(BOOL)enabled forBase:(NSString *)base;
- (VibeColor *)resolvedPlaylistColorForBase:(NSString *)base;

// The container files the record names — the custom:<sha1> files the image
// sweep is keyed on, across every image field.
+ (NSSet<NSString *> *)customImageFilesInRecord:(nullable NSDictionary<NSString *, id> *)record;

#pragma mark Dice

// The editor's two dice. Neither is uniform noise: each rolls a look a
// person might have picked, over the factory defaults.
//
// Settings rolls the main appearance choices — the window and playlist
// backgrounds and tints (never custom, which is a color), the corner radius,
// the waveform style, color theme and gradient, the button gradient and
// glyphs, the playlist columns — and the fonts: one face for the text from
// randomizableFontFaces, the numeric slots monospace half the time, every
// size at its factory value. Colors, the column color switches, the Info
// card, the Dock choice and every image stay as they are. The waveform
// styles are the caller's, since their registry belongs to the renderer.
- (void)randomizeSettingsWithWaveformStyles:(NSArray<NSString *> *)styles;

// Colors resets every color pair and rolls one palette from one hue: a
// pastel of it over the dark appearance, a deeper shade over light, in one
// of a few schemes — the header labels tinted, the playlist columns tinted
// with them, a complementary pair across title and artist, an analogous
// pair reaching the info card and the buttons, or a wash of the hue over
// the window and playlist tints. A scheme that draws a pair switches on
// whatever shows it (the custom waveform theme, the custom tints, the
// column switches); a leftover custom choice from an earlier roll snaps
// back. Nothing else moves.
- (void)randomizeColors;

// Three serif, three sans and a monospace face every macOS the app runs on
// ships — the whole set the settings die draws from.
+ (NSArray<NSString *> *)randomizableFontFaces;

@end

NS_ASSUME_NONNULL_END
