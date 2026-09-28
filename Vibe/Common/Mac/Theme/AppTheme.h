//
//  AppTheme.h
//  Vibe
//
// One theme: typed accessors over a sparse record holding only values that
// differ from the factory look, so the built-in Vibe theme is the empty
// record. All sanitization lives here — initWithRecord: and every setter run
// the same gate, so an import, a stored record and a UI edit obey one set of
// rules. Values are plist/JSON types, colors #RRGGBB[AA]. macOS-only.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

// A built-in's stable identifier; user themes use minted UUIDs, so the two
// cannot collide.
FOUNDATION_EXPORT NSString *const kVibeThemeIdentifierVibe;

// dual (the default) keeps a color set per appearance; single keeps ONE color
// per field and pins the window dark (requiredWindowAppearance). The
// art-keyed transport pairs are the exception.
#define SETTINGS_VALUE_THEME_MODE_SINGLE                    @"single"
#define SETTINGS_VALUE_THEME_MODE_DUAL                      @"dual"

// Window and playlist background styles: glass (default); solid covers it
// with the surface's color pair, alpha the opacity; clear drops the surface's
// pane so the window's Clear backdrop is the whole look. On the playlist,
// solid and clear both remove the behind-window blur.
#define SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS              @"glass"
#define SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID              @"solid"
#define SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR              @"clear"

// The Dock tile while a track with artwork plays: its cover (default), or the
// app icon throughout.
#define SETTINGS_VALUE_DOCK_ICON_ALBUM_ART                  @"album_art"
#define SETTINGS_VALUE_DOCK_ICON_APP_ICON                   @"app_icon"

#define SETTINGS_VALUE_BUTTON_GRADIENT_NONE                 @"none"
#define SETTINGS_VALUE_BUTTON_GRADIENT_HOVER                @"hover"
#define SETTINGS_VALUE_BUTTON_GRADIENT_ARTWORK              @"artwork"
#define SETTINGS_VALUE_BUTTON_GRADIENT_ALWAYS               @"always"

// The transport buttons' factory glyphs. The editor writes play and pause
// from one pick (SettingsRules.h); a JSON can set either.
#define kVibeThemePlaylistButtonGlyphDefault  @"list.bullet"
#define kVibeThemePlayButtonGlyphDefault      @"play.fill"
#define kVibeThemePauseButtonGlyphDefault     @"pause.fill"
#define kVibeThemeNextButtonGlyphDefault      @"forward.end.fill"

#define kVibeThemeCornerRadiusMax ((CGFloat)36)
// What a theme without a custom radius draws. The window is borderless and
// draws its own shape, so macOS 26's window radius is this constant.
#define kVibeThemeCornerRadiusDefault ((CGFloat)16)

#define kVibeThemeWaveformBarScaleMin 0.5
#define kVibeThemeWaveformBarScaleMax 2.0
#define kVibeThemeWaveformBarScaleDefault 1.0

// The font slots' factory point sizes.
#define kVibeThemeTitleFontBaseSize     ((CGFloat)23)
#define kVibeThemeArtistFontBaseSize   ((CGFloat)16)
#define kVibeThemeInfoFontBaseSize     ((CGFloat)13)
#define kVibeThemePlaylistFontBaseSize ((CGFloat)14)
#define kVibeThemePlaylistDurationFontBaseSize ((CGFloat)12)

// None is deliberately zero, so a zero-filled ivar or an unset control tag
// reads as no slot, never as the title.
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

// Keys beside the field overrides. The id never leaves the store: export
// strips it, import mints a fresh one.
FOUNDATION_EXPORT NSString *const kVibeThemeRecordNameKey;
FOUNDATION_EXPORT NSString *const kVibeThemeRecordIdentifierKey;

// The color pairs' base names: each record key less its Dark/Light suffix.
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
// The transport buttons' resting glyph colors; hover and disabled derive by
// SymbolButton's ratios. Keyed by the art UNDER the buttons, not the
// appearance, so both sides stay live under single mode.
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistButton;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlayButton;
FOUNDATION_EXPORT NSString *const kVibeThemeColorNextButton;
// The playlist's text columns, each behind a switch
// (playlistColorEnabledForBase:). Off (default), a column draws its label
// pair — title's for the title column, artist's for the rest; on, its own
// pair, an unset side inheriting the label pair. The pair survives the switch
// going off.
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistNumber;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistTitle;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistArtist;
FOUNDATION_EXPORT NSString *const kVibeThemeColorPlaylistDuration;

// The image fields. A value is "" (the factory image), "custom:<sha1>.<ext>"
// (a picked image in the app container) or "bundled:<name>.<ext>" (shipped
// in Resources/Themes/). Persisted keys: never renamed.
FOUNDATION_EXPORT NSString *const kVibeThemeImageDefaultArtworkDark;
FOUNDATION_EXPORT NSString *const kVibeThemeImageDefaultArtworkLight;
FOUNDATION_EXPORT NSString *const kVibeThemeImageAppIcon;
// Art-keyed pairs like the button colors; an unset side draws the other
// side's image before the glyph.
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

// Empty for vibe, and for an identifier that names no built-in.
+ (NSDictionary<NSString *, id> *)builtInRecordForIdentifier:(NSString *)identifier;

// The English name from the JSON; AppSettings overlays the translation.
+ (nullable NSString *)builtInNameForIdentifier:(NSString *)identifier;

#pragma mark Images

// In the editor's order.
+ (NSArray<NSString *> *)imageFieldKeys;

// Never nil: the named image, or the factory record image for "", an unknown
// name or a missing file — the placeholder's fallback. Cached for the app's
// lifetime, safe because custom names are content hashes and bundled images
// immutable per build. Other slots use customImageForKey:.
+ (NSImage *)imageForReference:(nullable NSString *)reference;

// YES when a valid reference names an image that is not there. The only way
// to tell "deliberately the default" from "the chosen image is gone", since
// imageForReference: falls back for both.
+ (BOOL)referenceIsMissing:(nullable NSString *)reference;

// Validates (JPEG or PNG, square, within pixel and byte caps), stores the
// bytes as-is, and returns "custom:<sha1>.<ext>", or nil with the reason.
+ (nullable NSString *)storeCustomImageData:(NSData *)data
                                      error:(NSError *_Nullable *_Nullable)error;

// Deletes every container image no record in `records` names. Files are
// shared by content hash, so deletion is a sweep: pass every record that can
// hold a reference.
+ (void)removeCustomImageFilesUnreferencedByRecords:(NSArray<NSDictionary *> *)records;

#pragma mark Names, migration and JSON

// A usable theme name: trimmed, length-capped, the fallback when empty, and
// suffixed " 2", " 3", … past any name already in use.
+ (NSString *)dedupedThemeName:(nullable NSString *)candidate
                      fallback:(NSString *)fallback
                 existingNames:(NSArray<NSString *> *)existingNames;

// The record to store as the migrated user theme, from the pre-theme values
// keyed by field name; nil when they sanitize to the defaults.
+ (nullable NSDictionary<NSString *, id> *)migratedRecordFromLegacyValues:
        (NSDictionary<NSString *, id> *)legacyValues;

// A theme JSON, both ways: version, name, then one object per editor section
// holding its fields under section-local keys. recordFromJSONData caps the
// size, requires an object, reports the name (nil when absent) and returns
// the sanitized flat record; an empty one is a valid theme.
+ (nullable NSDictionary<NSString *, id> *)recordFromJSONData:(NSData *)data
                                                         name:(NSString *_Nullable *_Nullable)outName
                                                        error:(NSError **)error;
+ (nullable NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                                  name:(NSString *)name;

// Sanitized: unknown keys and malformed values drop, identifiers snap,
// numbers clamp. nil builds the defaults.
- (instancetype)initWithRecord:(nullable NSDictionary<NSString *, id> *)record;

// The sparse record initWithRecord: would hold for this input.
+ (NSDictionary<NSString *, id> *)sanitizedRecord:(nullable NSDictionary<NSString *, id> *)record;

// Applies a theme in place, so holders of the object see the switch.
- (void)replaceWithRecord:(nullable NSDictionary<NSString *, id> *)record;

// The sparse record: the stored and exported form.
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

#pragma mark Fields

// Setters run the same gate as initWithRecord:.

@property (nonatomic, copy) NSString *waveformStyle;        // WaveformRendererRegistry identifier
@property (nonatomic, copy) NSString *mode;                 // single/dual color sets
@property (readonly, nonatomic) BOOL isSingleMode;
@property (nonatomic, copy) NSString *waveformTheme;        // mono/orange/album_art/custom
@property (nonatomic) BOOL waveformGradient;                // NO draws flat bars, no vertical ramp
@property (nonatomic) double waveformBarDensity;            // multiplier of the style's designed count
@property (nonatomic) double waveformBarWidth;              // multiplier of the style's designed thickness
@property (nonatomic, copy) NSString *windowTint;           // mono/artwork/custom
@property (nonatomic, copy) NSString *playlistTint;         // mono/artwork/custom; snaps to mono, the factory playlist wash
@property (nonatomic, copy) NSString *windowBackgroundStyle; // glass/solid/clear
@property (nonatomic, copy) NSString *playlistBackgroundStyle; // glass/solid/clear
// The slider's radius and whether the window draws it; off draws
// kVibeThemeCornerRadiusDefault. A record naming a radius but not the switch
// reads as custom, since the switch postdates the radius. Consumers read
// only resolvedWindowCornerRadius.
@property (nonatomic) CGFloat windowCornerRadius;
@property (nonatomic) BOOL customCornerRadius;
@property (readonly, nonatomic) CGFloat resolvedWindowCornerRadius;
@property (nonatomic, copy) NSString *dockIcon;             // album_art/app_icon
// YES (default) composes the Dock's album art and a custom app icon onto the
// icon grid; NO shows the picture as it is.
@property (nonatomic) BOOL appIconShape;
// The darkening behind the transport buttons: none/hover/artwork/always.
@property (nonatomic, copy) NSString *buttonGradient;
@property (nonatomic) BOOL showTransportButtons;
// SF Symbol names, checked for shape only: a name this macOS lacks draws the
// factory glyph. A button image wins over the glyph.
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
@property (nonatomic) BOOL showPlaylistNumberColumn;              // the playlist's number gutter
@property (nonatomic) BOOL showPlaylistArtworkColumn;             // the playlist's art column
@property (nonatomic) BOOL showPlaylistDurationColumn;            // the playlist's length column
@property (nonatomic) BOOL keyColorsEnabled;
@property (nonatomic, copy) NSString *keyNotation;          // camelot/musical

// An empty face is the built-in font. Faces are not validated: Fonts' never-nil
// fallback resolves an uninstalled one. The size clamps are narrow because the
// labels' frames are fixed. VibeFontSlotNone reads as "" at size 0 and drops
// writes.
- (NSString *)fontFaceForSlot:(VibeFontSlot)slot;
- (CGFloat)fontSizeForSlot:(VibeFontSlot)slot;
- (void)setFontFace:(NSString *)face size:(CGFloat)size forSlot:(VibeFontSlot)slot;

// The placeholder is the one appearance-keyed image pair: single mode reads
// and writes its dark slot from either side, as for colors. Picking a glyph
// clears the images it replaces, and Play also sets its paired Pause glyph.
+ (NSArray<NSString *> *)imageKeysForButton:(NSString *)key;
- (void)setGlyph:(NSString *)glyph forButtonImageKey:(NSString *)key;

- (NSString *)imageReferenceForKey:(NSString *)key;
- (void)setImageReference:(NSString *)reference forKey:(NSString *)key;
// nil unless the slot names a present image, so the app icon and buttons fall
// back to the bundle icon or the glyph, never the record image.
- (nullable NSImage *)customImageForKey:(NSString *)key;
// Its own image, else its partner side's; nil means draw the glyph.
- (nullable NSImage *)buttonImageForKey:(NSString *)key;
// The placeholder pair as ONE image: when the sides differ, a cached wrapper
// draws whichever side the drawing appearance asks for.
@property (readonly, nonatomic) NSImage *resolvedDefaultArtworkImage;
// One side, for a consumer rasterizing outside a view (Now Playing), where
// the drawing appearance is the system's, not the window's.
- (NSImage *)defaultArtworkImageForAppearance:(NSAppearance *)appearance;

// Color pairs by base name. nil is unset. Alpha is meaningful throughout.
- (nullable VibeColor *)colorForBase:(NSString *)base dark:(BOOL)isDark;
- (void)setColor:(nullable VibeColor *)color forBase:(NSString *)base dark:(BOOL)isDark;
// The pair pinned to one side, for the editor's wells: the override, or what
// an unset slot draws as, resolved under that side's appearance rather than
// the pane's.
- (VibeColor *)displayColorForBase:(NSString *)base dark:(BOOL)isDark;

// Dark for a single-mode theme, else nil. Unset defaults then draw their
// dark values, so a light background needs its label colors set too.
- (nullable NSAppearance *)requiredWindowAppearance;

// The label colors over their semantic fallbacks, each one dynamic color.
// Captured at call time: an appearance flip re-resolves, but a theme change
// must rebuild whatever holds one.
- (VibeColor *)resolvedTitleColor;
- (VibeColor *)resolvedArtistColor;
- (VibeColor *)resolvedInfoColor;
- (VibeColor *)resolvedTimeColor;

// By the four kVibeThemeColorPlaylist* text bases; captured like the above.
- (BOOL)playlistColorEnabledForBase:(NSString *)base;
- (void)setPlaylistColorEnabled:(BOOL)enabled forBase:(NSString *)base;
- (VibeColor *)resolvedPlaylistColorForBase:(NSString *)base;

// The custom: file names across every image field.
+ (NSSet<NSString *> *)customImageFilesInRecord:(nullable NSDictionary<NSString *, id> *)record;

#pragma mark Dice

// The editor's dice. Settings rolls the appearance choices and fonts, never
// colors, the column switches, the Info card, the Dock choice or images. The
// styles are passed in because their registry is the renderer's.
- (void)randomizeSettingsWithWaveformStyles:(NSArray<NSString *> *)styles;

// Resets every pair and paints one hue in one of five schemes, switching on
// whatever shows a painted pair and snapping a leftover custom choice back.
- (void)randomizeColors;

// Faces every supported macOS ships.
+ (NSArray<NSString *> *)randomizableFontFaces;

@end

NS_ASSUME_NONNULL_END
