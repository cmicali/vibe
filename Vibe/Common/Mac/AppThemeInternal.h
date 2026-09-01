//
//  AppThemeInternal.h
//  Vibe
//
//  The private surface shared between AppTheme.m and AppTheme+Archive.m: the
//  two artwork field keys, and the record-side helpers the archive form is
//  written in terms of. Do not use it outside the AppTheme implementation
//  files; everything else goes through AppTheme.h.
//

#import "AppTheme.h"

NS_ASSUME_NONNULL_BEGIN

// The default-artwork field keys — the one pair of record keys whose values
// name a file, so the one pair an archive carries entries for. Persisted;
// never renamed.
FOUNDATION_EXPORT NSString *const kFieldDefaultArtworkDark;
FOUNDATION_EXPORT NSString *const kFieldDefaultArtworkLight;

// Implemented in AppTheme.m.
@interface AppTheme ()

// The archive writer's form of JSONDataForRecord:name:. Inside a ZIP an image
// reference is the bare name of the entry beside the JSON, so artworkNames
// maps an artwork field to the entry the archive wrote for it. The rewrite
// cannot happen in the record the caller hands over: the sanitizer this runs
// first admits only the prefixed shapes and would drop a bare name entirely.
+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                          name:(NSString *)name
                  artworkNames:(nullable NSDictionary<NSString *, NSString *> *)artworkNames;

// The two artwork fields as WRITTEN in a theme JSON — trimmed, not sanitized —
// keyed by field, so a bare entry name an archive references survives here
// where the record's gate has already dropped it. Empty and absent are
// omitted.
+ (NSDictionary<NSString *, NSString *> *)rawDefaultArtworkReferencesInJSONData:(NSData *)json;

// The bytes a bundled: value names in this build's Resources/Themes, or a
// custom: value in the container; nil for "", a name nothing holds, and any
// other value.
+ (nullable NSData *)dataForDefaultArtwork:(nullable NSString *)value;

@end

NS_ASSUME_NONNULL_END
