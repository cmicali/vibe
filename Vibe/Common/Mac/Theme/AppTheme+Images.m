//
//  AppTheme+Images.m
//  Vibe
//

#import "AppThemeInternal.h"
#import <AppKit/AppKit.h>
#import "PlatformImage.h"
#import "NSView+DarkMode.h"
#import "NSURL+Hash.h"
#import "PlatformColor.h"
#import "NSImage+Util.h"

@implementation AppTheme (Images)

+ (NSArray<NSString *> *)imageFieldKeys {
    return VibeThemeImageFieldKeys();
}

+ (NSString *)archiveEntryStemForImageKey:(NSString *)key {
    return VibeThemeFieldSpecsByKey()[key][kSpecArchiveEntry];
}

// Never renamed: every install's images are already there.
static NSString *VibeCustomImageDirectory(void) {
#if DEBUG
    // Test seam: the unsandboxed host-less suite would otherwise write into
    // the real ~/Library.
    const char *override = getenv("VIBE_THEME_ART_DIR");
    if (override) {
        return [NSString stringWithUTF8String:override];
    }
#endif
    NSString *support = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[support stringByAppendingPathComponent:
            NSBundle.mainBundle.bundleIdentifier ?: @"Vibe"]
            stringByAppendingPathComponent:@"ThemeArt"];
}

// The file name after either prefix, or nil.
static NSString *_Nullable VibeImageFileName(NSString *_Nullable reference) {
    for (NSString *prefix in @[@"custom:", @"bundled:"]) {
        if ([reference hasPrefix:prefix]) {
            return [reference substringFromIndex:prefix.length];
        }
    }
    return nil;
}

static NSString *_Nullable VibeCustomImagePath(NSString *_Nullable reference) {
    if (![reference hasPrefix:@"custom:"]) {
        return nil;
    }
    return [VibeCustomImageDirectory() stringByAppendingPathComponent:VibeImageFileName(reference)];
}

// nil also for a name THIS build does not ship, which lets an archive's copy
// stand in. Callers pass a sanitized value: the shape gate keeps a crafted
// name out of the bundle lookup.
static NSURL *_Nullable VibeBundledImageURL(NSString *_Nullable reference) {
    if (![reference hasPrefix:@"bundled:"]) {
        return nil;
    }
    NSString *file = VibeImageFileName(reference);
    return [[NSBundle bundleForClass:AppTheme.class]
            URLForResource:file.stringByDeletingPathExtension
             withExtension:file.pathExtension subdirectory:@"Themes"];
}

// Returns the extension, or nil with the reason.
static const NSInteger kImagePixelCap = 4096;
static const NSInteger kImagePixelFloor = 64;

static NSString *VibeValidatedImageExtension(NSData *data, NSString **outReason) {
    *outReason = nil;
    if (data.length == 0 || data.length > kVibeThemeImageByteCap) {
        *outReason = @"the image is empty or over 8 MB";
        return nil;
    }
    const uint8_t *b = data.bytes;
    NSString *ext = nil;
    if (data.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
        ext = @"jpg";
    } else if (data.length > 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') {
        ext = @"png";
    } else {
        *outReason = @"the image must be a JPEG or PNG";
        return nil;
    }
    CGSize pixels = VibeEncodedImagePixelSize(data);
    NSInteger width = (NSInteger)pixels.width;
    if (width < kImagePixelFloor || width > kImagePixelCap || pixels.width != pixels.height) {
        *outReason = @"the image must be square, between 64 and 4096 pixels";
        return nil;
    }
    return ext;
}

+ (BOOL)referenceIsMissing:(NSString *)reference {
    if (!VibeIsValidImageReference(reference)) {
        return NO;
    }
    if ([reference hasPrefix:@"bundled:"]) {
        return VibeBundledImageURL(reference) == nil;
    }
    return ![NSFileManager.defaultManager fileExistsAtPath:VibeCustomImagePath(reference)];
}

+ (NSString *)storeCustomImageData:(NSData *)data error:(NSError **)error {
    NSString *reason = nil;
    NSString *ext = VibeValidatedImageExtension(data, &reason);
    if (!ext) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:3
                    userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return nil;
    }
    NSString *hex = [data sha1Hex];
    NSString *directory = VibeCustomImageDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *file = [NSString stringWithFormat:@"%@.%@", hex, ext];
    NSString *path = [directory stringByAppendingPathComponent:file];
    if (![NSFileManager.defaultManager fileExistsAtPath:path] &&
        ![data writeToFile:path atomically:YES]) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:4
                    userInfo:@{NSLocalizedDescriptionKey: @"could not save the image"}];
        }
        return nil;
    }
    return [@"custom:" stringByAppendingString:file];
}

+ (NSSet<NSString *> *)customImageFilesInRecord:(NSDictionary<NSString *, id> *)record {
    NSMutableSet<NSString *> *files = [NSMutableSet set];
    for (NSString *key in VibeThemeImageFieldKeys()) {
        NSString *value = [record[key] isKindOfClass:NSString.class] ? record[key] : nil;
        if ([value hasPrefix:@"custom:"]) {
            [files addObject:VibeImageFileName(value)];
        }
    }
    return files;
}

+ (void)removeCustomImageFilesUnreferencedByRecords:(NSArray<NSDictionary *> *)records {
    NSMutableSet<NSString *> *referenced = [NSMutableSet set];
    for (NSDictionary *record in records) {
        [referenced unionSet:[self customImageFilesInRecord:record]];
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *directory = VibeCustomImageDirectory();
    for (NSString *file in [manager contentsOfDirectoryAtPath:directory error:NULL]) {
        if (![referenced containsObject:file]) {
            [manager removeItemAtPath:[directory stringByAppendingPathComponent:file]
                                error:NULL];
        }
    }
}

// The one read behind the image cache and the archive; nil when nothing
// holds the name.
+ (NSData *)dataForReference:(NSString *)reference {
    NSURL *bundled = VibeBundledImageURL(reference);
    if (bundled) {
        return [NSData dataWithContentsOfURL:bundled];
    }
    NSString *path = VibeCustomImagePath(reference);
    return path ? [NSData dataWithContentsOfFile:path] : nil;
}

static NSMutableDictionary<NSString *, NSImage *> *ImageCache(void) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

+ (NSImage *)imageForReference:(NSString *)reference {
    NSMutableDictionary<NSString *, NSImage *> *cache = ImageCache();
    NSString *key = VibeIsValidImageReference(reference) ? reference : @"";
    @synchronized (cache) {
        NSImage *cached = cache[key];
        if (cached) {
            return cached;
        }
    }
    // Read and decode outside the lock, so a first decode stalls no other
    // consumer. Synchronous on purpose: the caller needs an image now, once
    // per key. Bounded to the mac's display-art size, so a 4096px original is
    // never pinned full-size for the app's lifetime.
    NSData *data = [self dataForReference:key];
    NSImage *image = data ? VibeDecodedImageWithData(data, kVibeArchivedDisplayArtDimension) : nil;
    if (!image && key.length) {
        // TRAP: never cache the fallback under the missing image's key. Names
        // are content hashes, so re-storing that image reuses the key and the
        // theme would draw the factory record until relaunch.
        return [self imageForReference:@""];
    }
    // The blank square is for the host-less tests, which have no asset
    // catalog.
    image = image ?: [NSImage imageNamed:@"record-bg"]
            ?: [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    @synchronized (cache) {
        // Double-checked: consumers compare pointer identity to skip
        // reinstalling an unchanged placeholder.
        NSImage *raced = cache[key];
        if (raced) {
            return raced;
        }
        if ([key hasPrefix:@"custom:"]) {
            // A live theme needs at most one custom image per field; past
            // that, drop them (and composites wrapping them) so auditioned
            // images are not pinned forever.
            NSUInteger customs = 0;
            for (NSString *held in cache) {
                customs += [held hasPrefix:@"custom:"] ? 1 : 0;
            }
            if (customs >= VibeThemeImageFieldKeys().count) {
                for (NSString *stale in [cache.allKeys copy]) {
                    if ([stale hasPrefix:@"custom:"] || ([stale hasPrefix:@"dual|"]
                            && [stale containsString:@"custom:"])) {
                        [cache removeObjectForKey:stale];
                    }
                }
            }
        }
        cache[key] = image;
        return image;
    }
}

// Cached, because consumers compare pointer identity; identical sides skip
// the wrapper, keeping single mode and the factory look a plain image.
+ (NSImage *)imageForDefaultArtworkDark:(NSString *)darkValue light:(NSString *)lightValue {
    NSImage *dark = [self imageForReference:darkValue];
    NSImage *light = [self imageForReference:lightValue];
    if (dark == light) {
        return dark;
    }
    // "dual|" cannot collide with a stored value: "|" fails the value shape.
    NSString *key = [NSString stringWithFormat:@"dual|%@|%@", darkValue ?: @"", lightValue ?: @""];
    NSMutableDictionary<NSString *, NSImage *> *cache = ImageCache();
    @synchronized (cache) {
        NSImage *cached = cache[key];
        if (cached) {
            return cached;
        }
        NSSize size = NSMakeSize(MAX(dark.size.width, light.size.width),
                                 MAX(dark.size.height, light.size.height));
        NSImage *image = [NSImage imageWithSize:size flipped:NO
                                 drawingHandler:^BOOL(NSRect rect) {
            [(NSAppearance.currentDrawingAppearance.isDark ? dark : light)
                    drawInRect:rect fromRect:NSZeroRect
                    operation:NSCompositingOperationCopy fraction:1];
            return YES;
        }];
        cache[key] = image;
        return image;
    }
}

// One object for the app's lifetime: consumers compare identity to skip
// reinstalling an unchanged placeholder.
+ (NSImage *)clearDefaultArtworkImage {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        image = [NSImage imageWithSize:NSMakeSize(kVibeArchivedDisplayArtDimension, kVibeArchivedDisplayArtDimension)
                               flipped:NO drawingHandler:^BOOL(NSRect rect) { return YES; }];
    });
    return image;
}

// One entry per kind, not the image cache: a well or slider drag mints a
// value per tick, and each value is a new image so the identity check
// reinstalls it.
static NSImage *OneDefaultArtworkSquare(NSString *kind, NSString *wanted, NSImage *(^make)(void)) {
    static NSMutableDictionary<NSString *, NSImage *> *images;
    static NSMutableDictionary<NSString *, NSString *> *keys;
    @synchronized (AppTheme.class) {
        if (!images) {
            images = [NSMutableDictionary dictionary];
            keys = [NSMutableDictionary dictionary];
        }
        if (![keys[kind] isEqualToString:wanted]) {
            keys[kind] = wanted;
            images[kind] = make();
        }
        return images[kind];
    }
}

+ (NSImage *)imageForDefaultArtworkColorDark:(NSColor *)dark light:(NSColor *)light {
    NSString *wanted = [NSString stringWithFormat:@"%@|%@",
                        VibeHexStringFromColor(dark), VibeHexStringFromColor(light)];
    return OneDefaultArtworkSquare(@"color", wanted, ^NSImage *{
        return [NSImage imageWithSize:NSMakeSize(kVibeArchivedDisplayArtDimension, kVibeArchivedDisplayArtDimension)
                              flipped:NO drawingHandler:^BOOL(NSRect rect) {
            [(NSAppearance.currentDrawingAppearance.isDark ? dark : light) set];
            NSRectFillUsingOperation(rect, NSCompositingOperationCopy);
            return YES;
        }];
    });
}

+ (NSImage *)imageForDefaultArtworkGlyph:(NSString *)glyph size:(double)size
                                    dark:(NSColor *)dark light:(NSColor *)light {
    NSString *wanted = [NSString stringWithFormat:@"%@|%.3f|%@|%@", glyph, size,
                        VibeHexStringFromColor(dark), VibeHexStringFromColor(light)];
    return OneDefaultArtworkSquare(@"glyph", wanted, ^NSImage *{
        NSString *name = [NSImage imageWithSystemSymbolName:glyph accessibilityDescription:nil]
                ? glyph : kVibeThemeDefaultArtworkGlyphDefault;
        return [NSImage imageWithSize:NSMakeSize(kVibeArchivedDisplayArtDimension, kVibeArchivedDisplayArtDimension)
                              flipped:NO drawingHandler:^BOOL(NSRect rect) {
            NSColor *color = NSAppearance.currentDrawingAppearance.isDark ? dark : light;
            NSImage *symbol = [NSImage symbolNamed:name pointSize:rect.size.height * size
                                            weight:NSFontWeightRegular palette:@[color]
                          accessibilityDescription:nil];
            NSSize drawn = symbol.size;
            [symbol drawInRect:NSMakeRect(NSMidX(rect) - drawn.width / 2, NSMidY(rect) - drawn.height / 2,
                                          drawn.width, drawn.height)
                      fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
            return YES;
        }];
    });
}

@end
