//
//  AppTheme+Archive.h
//  Vibe
//
//  A theme as a file: the ZIP carrying theme.json beside its images, and the
//  import funnel that takes either that or plain JSON.
//

#import "AppTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface AppTheme (Archive)

// A ZIP of theme.json and every image the record names, bundled ones included
// (the opening build may not ship them). Entries are named by slot
// (artwork_default_front.png, button_play_dark.png), theme.json referencing
// them bare; fields naming one image share an entry. nil when the record
// names no resolvable image — export plain JSON instead.
+ (nullable NSData *)archiveDataForRecord:(NSDictionary<NSString *, id> *)record
                                     name:(NSString *)name;

// Imports raw JSON or a ZIP. Every archived image is re-validated and stored
// as custom:<sha1>, a built-in's included; the entry name is not trusted. A
// JSON-only import drops a dangling custom reference.
+ (nullable NSDictionary<NSString *, id> *)recordFromJSONOrArchiveData:(nullable NSData *)data
                                                                  name:(NSString *_Nullable *_Nullable)outName
                                                                 error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
