//
//  AppThemeInternal.h
//  Vibe
//
//  The seam between AppTheme.m and AppTheme+Archive.m. Nothing else imports
//  it.
//

#import "AppTheme.h"

NS_ASSUME_NONNULL_BEGIN

// An image's byte ceiling; the archive's budget is sized from it.
static const NSUInteger kVibeThemeImageByteCap = 8 * 1024 * 1024;

@interface AppTheme ()

// The slot-named archive entry, less extension (artwork_default_front,
// button_play_dark). Persisted in exported archives: never renamed.
+ (NSString *)archiveEntryStemForImageKey:(NSString *)key;

// entryNames maps an image field to its bare archive entry name, applied
// after sanitizing, which would drop a bare name.
+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                          name:(NSString *)name
                    entryNames:(nullable NSDictionary<NSString *, NSString *> *)entryNames;

// The image fields as written, trimmed but not sanitized, so a bare entry
// name survives.
+ (NSDictionary<NSString *, NSString *> *)rawImageReferencesInJSONData:(NSData *)json;

// nil for "" and for a name nothing holds.
+ (nullable NSData *)dataForReference:(nullable NSString *)reference;

@end

NS_ASSUME_NONNULL_END
