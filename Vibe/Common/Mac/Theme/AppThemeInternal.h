//
//  AppThemeInternal.h
//  Vibe
//
//  The seam between AppTheme.m, the record, and its categories: Images, JSON,
//  Dice and Archive. Nothing else imports it.
//

#import "AppTheme.h"

NS_ASSUME_NONNULL_BEGIN

// An image's byte ceiling; the archive's budget is sized from it.
static const NSUInteger kVibeThemeImageByteCap = 8 * 1024 * 1024;

// A VibeThemeFieldSpecs() row's keys.
static NSString *const kSpecKey = @"key";
static NSString *const kSpecGroup = @"group";
static NSString *const kSpecJSONKey = @"json";
static NSString *const kSpecDefault = @"default";
static NSString *const kSpecColorBase = @"colorBase";
static NSString *const kSpecInheritsBase = @"inheritsBase";
static NSString *const kSpecArchiveEntry = @"archiveEntry";
static NSString *const kSpecSanitize = @"sanitize";
static NSString *const kSpecOpaque = @"opaque";

// The schema and the tables derived from it, in AppTheme.m.
NSArray<NSDictionary *> *VibeThemeFieldSpecs(void);
NSDictionary<NSString *, NSDictionary *> *VibeThemeFieldSpecsByKey(void);
NSArray<NSString *> *VibeThemeImageFieldKeys(void);
NSDictionary<NSString *, NSString *> *VibeThemePlaylistColorFallbackBases(void);
NSString *_Nullable VibeTrimmedCappedString(id _Nullable raw);
BOOL VibeIsValidImageReference(NSString *_Nullable value);

@interface AppTheme () {
    NSMutableDictionary<NSString *, id> *_fields;
    // Keyed by hex VALUE, so it never goes stale. Rows read fills per draw.
    NSMutableDictionary<NSString *, VibeColor *> *_parsedColors;
    // resolvedDefaultArtworkImage's drawn square and the fields it was made
    // from.
    NSImage *_defaultArtworkSquare;
    NSString *_defaultArtworkSquareKey;
}

// The record key a pair's side reads and writes.
- (NSString *)colorKeyForBase:(NSString *)base dark:(BOOL)isDark;

@end

// In AppTheme+Images.m.
@interface AppTheme (ImagesInternal)

// The slot-named archive entry, less extension (artwork_default_front,
// button_play_dark). Persisted in exported archives: never renamed.
+ (NSString *)archiveEntryStemForImageKey:(NSString *)key;

// nil for "" and for a name nothing holds.
+ (nullable NSData *)dataForReference:(nullable NSString *)reference;

// The placeholder pair as one image (resolvedDefaultArtworkImage).
+ (NSImage *)imageForDefaultArtworkDark:(NSString *)darkValue light:(NSString *)lightValue;
// The one transparent square clear and window draw.
+ (NSImage *)clearDefaultArtworkImage;
// Fresh squares, uncached: the record memoizes the one it shows. The color
// pair as a square, and a symbol this macOS has centered on a transparent
// square, each in the pair's color for the drawing appearance.
+ (NSImage *)imageForDefaultArtworkColorDark:(NSColor *)dark light:(NSColor *)light;
+ (NSImage *)imageForDefaultArtworkGlyph:(NSString *)glyph size:(double)size
                                    dark:(NSColor *)dark light:(NSColor *)light;

@end

// In AppTheme+JSON.m.
@interface AppTheme (JSONInternal)

// entryNames maps an image field to its bare archive entry name, applied
// after sanitizing, which would drop a bare name.
+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                          name:(NSString *)name
                    entryNames:(nullable NSDictionary<NSString *, NSString *> *)entryNames;

// The image fields as written, trimmed but not sanitized, so a bare entry
// name survives.
+ (NSDictionary<NSString *, NSString *> *)rawImageReferencesInJSONData:(NSData *)json;

@end

NS_ASSUME_NONNULL_END
