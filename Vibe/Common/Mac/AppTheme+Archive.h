//
//  AppTheme+Archive.h
//  Vibe
//
//  A theme as a FILE: the ZIP that carries a theme's JSON beside its
//  default-artwork image(s), and the import funnel that takes either that or
//  plain JSON. What a theme IS — its fields and clamps, its colors, the
//  artwork store and the JSON form of the record — is AppTheme; this is only
//  how one travels. The codec is self-contained: the writer emits stored
//  entries, the reader takes stored and raw-deflate (a hand-made Finder zip),
//  and nothing links an archive library.
//

#import "AppTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface AppTheme (Archive)


// A theme whose record names a default-artwork image — a custom: one the user
// picked or the bundled: one a built-in ships — exports as a ZIP of theme.json
// and the image files; one naming none exports as plain JSON
// (JSONDataForRecord:). A built-in's image travels even though this build
// ships it, because the build that opens the archive may not be this one.
// Entries are named by SLOT — artwork_default_front/back.<ext>, the theme
// JSON referencing them bare — since a content hash or one build's resource
// filename reads as nothing to a person opening the ZIP; both sides naming
// one image share its entry. Returns nil when the record names no resolvable
// image.
+ (nullable NSData *)archiveDataForRecord:(NSDictionary<NSString *, id> *)record
                                     name:(NSString *)name;

// Imports either form: raw JSON, or a ZIP holding one .json plus images. An
// archived art reference is re-validated and re-hashed from the shipped image
// (the filename is not trusted) and the returned record points at the stored
// custom:<sha1> copy — every archived image lands there, a built-in's
// included. A JSON-only import with a dangling custom reference drops the
// field.
+ (nullable NSDictionary<NSString *, id> *)recordFromJSONOrArchiveData:(nullable NSData *)data
                                                                  name:(NSString *_Nullable *_Nullable)outName
                                                                 error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
