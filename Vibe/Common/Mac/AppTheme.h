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
// stop caring.
#define SETTINGS_VALUE_THEME_MODE_SINGLE                    @"single"
#define SETTINGS_VALUE_THEME_MODE_DUAL                      @"dual"

// The background styles' stable identifiers, shared by the window and the
// playlist: glass, the default, is the translucent look as shipped; solid
// covers it with the surface's color pair, whose alpha is the cover's
// opacity. On the playlist, solid also removes the behind-window blur.
#define SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS              @"glass"
#define SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID              @"solid"

// The corner-radius clamp's ceiling. A macro rather than an exported const
// because the header panel's right bleed is a compile-time frame sized to it
// — a static frame that must stay valid for every legal radius rather than
// follow the live value.
#define kVibeThemeCornerRadiusMax ((CGFloat)30)
// The factory radius — the editor's slider detent snaps back to it.
#define kVibeThemeCornerRadiusDefault ((CGFloat)20)

// The font slots' reference sizes — the base each slot's reference site
// passes (the title, the info labels, the playlist rows). Macros for the same
// reason as the radius max: compile-time constants shared by the theme
// defaults, Fonts' offset math and the reference call sites, so the offset
// arithmetic cannot skew against a copy.
#define kVibeThemeMainFontBaseSize     ((CGFloat)23)
#define kVibeThemeInfoFontBaseSize     ((CGFloat)13)
#define kVibeThemePlaylistFontBaseSize ((CGFloat)14)
#define kVibeThemePlaylistDurationFontBaseSize ((CGFloat)12)

// Keys a theme JSON carries beside the field overrides. The name travels on
// export/import; the version marks the schema; a record's id never leaves the
// store — export strips it, import mints a fresh one.
FOUNDATION_EXPORT NSString *const kVibeThemeRecordNameKey;
FOUNDATION_EXPORT NSString *const kVibeThemeRecordVersionKey;
FOUNDATION_EXPORT NSString *const kVibeThemeRecordIdentifierKey;

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

#pragma mark Default album art

// Never nil: the resolved placeholder for a theme's defaultAlbumArt value —
// the bundled or container image it names, or the factory record image for
// "", an unknown name, or a missing file. Cached for the app's lifetime;
// custom references are content-hashed, so a changed image is a new key.
+ (NSImage *)imageForDefaultAlbumArt:(nullable NSString *)value;

// The bundled choices: the filename stems under Resources/Themes/art.
+ (NSArray<NSString *> *)bundledAlbumArtNames;

// Validates (JPEG or PNG, square, within pixel and byte caps), copies into
// the app container, and returns the record value ("custom:<sha1>.<ext>"),
// or nil with the reason. The bytes are stored as-is, never re-encoded.
+ (nullable NSString *)storeCustomAlbumArtData:(NSData *)data
                                         error:(NSError *_Nullable *_Nullable)error;

#pragma mark Theme archives (JSON + image)

// A theme whose record carries a custom image exports as a ZIP of theme.json
// and the image file; one without exports as plain JSON (JSONDataForRecord:).
// Returns nil when the record has no resolvable custom image.
+ (nullable NSData *)archiveDataForRecord:(NSDictionary<NSString *, id> *)record
                                     name:(NSString *)name;

// Imports either form: raw JSON, or a ZIP holding one .json plus images. A
// custom-art reference is re-validated and re-hashed from the shipped image
// (the filename is not trusted) and the returned record points at the stored
// copy; a JSON-only import with a dangling custom reference drops the field.
+ (nullable NSDictionary<NSString *, id> *)recordFromJSONOrArchiveData:(NSData *)data
                                                                  name:(NSString *_Nullable *_Nullable)outName
                                                                 error:(NSError *_Nullable *_Nullable)error;

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

// A theme JSON, both ways. recordFromJSONData caps the input size, requires a
// JSON object, reports the name it carried (nil when absent), and returns the
// sanitized sparse record — an empty record is a valid theme that looks like
// the defaults. JSONDataForRecord composes record + version + name, sorted
// and pretty-printed. The id key never travels: export strips it, import
// mints a fresh one.
+ (nullable NSDictionary<NSString *, id> *)recordFromJSONData:(NSData *)data
                                                         name:(NSString *_Nullable *_Nullable)outName
                                                        error:(NSError **)error;
+ (nullable NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                                  name:(NSString *)name;

// Sanitized: unknown keys are dropped (a newer build's fields import as the
// defaults), malformed values are dropped, identifiers snap to their ladders,
// numbers clamp. nil builds the defaults — the Vibe look.
- (instancetype)initWithRecord:(nullable NSDictionary<NSString *, id> *)record;

// Repopulates every field from the record — applying a theme in place, so
// holders of the object see the switch.
- (void)replaceWithRecord:(nullable NSDictionary<NSString *, id> *)record;

// The sparse record: only fields differing from the defaults. This is the
// stored and exported form.
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

#pragma mark Fields

// Setters sanitize exactly like initWithRecord:, so the UI cannot store what
// a file load would refuse.

@property (nonatomic, copy) NSString *waveformStyle;        // renderer styleIdentifier
@property (nonatomic, copy) NSString *mode;                 // single/dual color sets
@property (readonly, nonatomic) BOOL isSingleMode;
@property (nonatomic, copy) NSString *waveformTheme;        // mono/orange/album_art/custom
@property (nonatomic) BOOL waveformGradient;                // NO draws flat bars, no vertical ramp
@property (nonatomic, copy) NSString *windowTint;           // mono/artwork/custom
@property (nonatomic, copy) NSString *playlistTint;         // mono/artwork/custom; snaps to mono, the factory playlist wash
@property (nonatomic, copy) NSString *windowBackgroundStyle; // glass/solid
@property (nonatomic, copy) NSString *playlistBackgroundStyle; // glass/solid
@property (nonatomic) CGFloat windowCornerRadius;           // clamped [0, kVibeThemeCornerRadiusMax]
@property (nonatomic) BOOL showFileInfo;
@property (nonatomic) BOOL showRemainingTime;
@property (nonatomic) BOOL showBPM;
@property (nonatomic) BOOL showKey;
@property (nonatomic) BOOL showPlaylistArtwork;             // the playlist's art column
@property (nonatomic) BOOL showPlaylistDuration;            // the playlist's length column
@property (nonatomic) BOOL keyColorsEnabled;
@property (nonatomic, copy) NSString *keyNotation;          // camelot/musical

// The four font slots. An empty face means the built-in font — Fonts owns
// what that resolves to, and resolves an uninstalled face with its never-nil
// fallback, so faces are not validated here. Sizes are absolute at each
// slot's reference site (title 23, info 13, playlist 14, playlist duration 12); call sites derive
// their own size as an offset from that base, which is why the clamps are
// narrow — the frames the labels sit in are fixed.
@property (nonatomic, copy) NSString *mainFontFace;
@property (nonatomic) CGFloat mainFontSize;                 // clamped [20, 26]
@property (nonatomic, copy) NSString *infoFontFace;
@property (nonatomic) CGFloat infoFontSize;                 // clamped [10, 15]
@property (nonatomic, copy) NSString *playlistFontFace;
@property (nonatomic) CGFloat playlistFontSize;             // clamped [11, 16]
@property (nonatomic, copy) NSString *playlistDurationFontFace;
@property (nonatomic) CGFloat playlistDurationFontSize;     // clamped [10, 14]

// The no-artwork placeholder: "" (the default) is the factory record image; a
// bundled name picks Resources/Themes/art/<name>.png|jpg; "custom:<sha1>.<ext>"
// names an image the user picked, copied into the app container. Resolution
// and its lifetime cache are imageForDefaultAlbumArt: below.
@property (nonatomic, copy) NSString *defaultAlbumArt;
// This theme's resolved placeholder — imageForDefaultAlbumArt: over the field.
@property (readonly, nonatomic) NSImage *resolvedDefaultAlbumArtImage;

// Per-appearance color pairs — one color per appearance, like every stored
// color pair before them. nil means unset: the consumer draws today's
// default, stated beside where it was hardcoded. Alpha is meaningful
// throughout (a fill's strength, the solid background's opacity).
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

// A per-appearance override pair over a semantic fallback, as one dynamic
// color: a nil override resolves to the fallback in that appearance. The
// pair is captured at call time, so a theme change means rebuilding whatever
// holds the color — an appearance flip re-resolves by itself.
+ (VibeColor *)dynamicColorWithDark:(nullable VibeColor *)dark
                              light:(nullable VibeColor *)light
                           fallback:(VibeColor *)fallback;

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
// tertiaryLabelColor — spelled once, so the header, the playlist and the
// corner readouts cannot disagree about a slot's fallback. Same capture
// semantics as dynamicColorWithDark: above.
- (VibeColor *)resolvedTitleColor;
- (VibeColor *)resolvedArtistColor;
- (VibeColor *)resolvedInfoColor;
- (VibeColor *)resolvedTimeColor;

@end

NS_ASSUME_NONNULL_END
