//
//  AppThemeInternal.h
//  Vibe
//
//  The private surface shared between AppTheme.m and AppTheme+Archive.m: the
//  record-side helpers the archive form is written in terms of. Do not use
//  it outside the AppTheme implementation files; everything else goes
//  through AppTheme.h.
//

#import "AppTheme.h"

NS_ASSUME_NONNULL_BEGIN

// A picked or shipped image's byte ceiling — the store's validation cap,
// and what the archive's whole-file budget is sized from.
static const NSUInteger kVibeThemeImageByteCap = 8 * 1024 * 1024;

// Implemented in AppTheme.m.
@interface AppTheme ()

// The archive entry an image field travels as, less the extension —
// artwork_default_front for the dark placeholder, app_icon, button_play…
// Named by slot, never by where the bytes came from. Persisted in every
// exported archive; never renamed.
+ (NSString *)archiveEntryStemForImageKey:(NSString *)key;

// The archive writer's form of JSONDataForRecord:name:. Inside a ZIP an image
// reference is the bare name of the entry beside the JSON, so entryNames
// maps an image field to the entry the archive wrote for it. The rewrite
// cannot happen in the record the caller hands over: the sanitizer this runs
// first admits only the prefixed shapes and would drop a bare name entirely.
+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                          name:(NSString *)name
                    entryNames:(nullable NSDictionary<NSString *, NSString *> *)entryNames;

// The image fields as WRITTEN in a theme JSON — trimmed, not sanitized —
// keyed by field, so a bare entry name an archive references survives here
// where the record's gate has already dropped it. Empty and absent are
// omitted.
+ (NSDictionary<NSString *, NSString *> *)rawImageReferencesInJSONData:(NSData *)json;

// The bytes a bundled: reference names in this build's Resources/Themes, or
// a custom: one in the container; nil for "", a name nothing holds, and any
// other value.
+ (nullable NSData *)dataForReference:(nullable NSString *)reference;

@end

NS_ASSUME_NONNULL_END
