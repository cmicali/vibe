//
//  Fonts.m
//  Vibe
//

#import "Fonts.h"
#import "AppTheme.h" // the slots' reference base sizes

@implementation Fonts {

}

+ (NSFont *)font:(CGFloat)size {
    return [self font:size bold:NO];
}

// Negating the size for bold collides at size 0, so the key spells out both
// dimensions.
static NSString *fontCacheKey(CGFloat size, BOOL bold) {
    return [NSString stringWithFormat:@"%g%@", size, bold ? @"-bold" : @""];
}

+ (NSFont *)font:(CGFloat)size bold:(BOOL)bold {
    static NSMutableDictionary<NSString *, NSFont *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary new];
    });
    NSString *key = fontCacheKey(size, bold);
    // NSMutableDictionary is not thread-safe and not every caller is on the
    // main thread. A duplicate create inside the lock is harmless.
    @synchronized (cache) {
        NSFont *font = cache[key];
        if (!font) {
            font = [NSFont fontWithName:bold ? @"HelveticaNeue-Bold" : @"HelveticaNeue-Medium" size:size];
            if (!font) {
                // Never return nil. Callers put the result straight into
                // attribute dictionaries, where nil raises.
                font = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightBold : NSFontWeightMedium];
            }
            cache[key] = font;
        }
        return font;
    }
}

+ (NSFont *)fontForNumbers:(CGFloat)size {
    return [self fontForNumbers:size bold:NO];
}

+ (NSFont *)fontForNumbers:(CGFloat)size bold:(BOOL)bold {
    static NSMutableDictionary<NSString *, NSFont *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary new];
    });
    NSString *key = fontCacheKey(size, bold);
    @synchronized (cache) {
        NSFont *font = cache[key];
        if (!font) {
            font = [NSFont monospacedDigitSystemFontOfSize:size weight:bold?NSFontWeightBold:NSFontWeightRegular];
            cache[key] = font;
        }
        return font;
    }
}

#pragma mark Themed slots

typedef NS_ENUM(NSInteger, VibeFontSlot) {
    VibeFontSlotTitle = 0,
    VibeFontSlotInfo,
    VibeFontSlotPlaylist,
    VibeFontSlotPlaylistDuration,
    VibeFontSlotArtist,
};

// The slots' reference bases — the sizes their reference sites pass — and the
// pushed configuration. All access is under @synchronized(Fonts.class): not
// every caller is on the main thread, same as the caches above.
static const CGFloat kSlotBase[5] = {kVibeThemeTitleFontBaseSize, kVibeThemeInfoFontBaseSize,
                                     kVibeThemePlaylistFontBaseSize,
                                     kVibeThemePlaylistDurationFontBaseSize,
                                     kVibeThemeArtistFontBaseSize};
static NSString *slotFace[5];
static CGFloat slotOffset[5];
static NSMutableDictionary<NSString *, NSFont *> *slotCache;

+ (void)applyThemeFonts:(AppTheme *)theme {
    NSString *faces[5] = {
        [VibeFontSlotTitle]            = theme.titleFontFace,
        [VibeFontSlotArtist]           = theme.artistFontFace,
        [VibeFontSlotInfo]             = theme.infoFontFace,
        [VibeFontSlotPlaylist]         = theme.playlistFontFace,
        [VibeFontSlotPlaylistDuration] = theme.playlistDurationFontFace,
    };
    CGFloat sizes[5] = {
        [VibeFontSlotTitle]            = theme.titleFontSize,
        [VibeFontSlotArtist]           = theme.artistFontSize,
        [VibeFontSlotInfo]             = theme.infoFontSize,
        [VibeFontSlotPlaylist]         = theme.playlistFontSize,
        [VibeFontSlotPlaylistDuration] = theme.playlistDurationFontSize,
    };
    @synchronized (self) {
        for (NSUInteger slot = 0; slot < 5; slot++) {
            slotFace[slot] = faces[slot].length ? faces[slot] : nil;
            slotOffset[slot] = sizes[slot] - kSlotBase[slot];
        }
        [slotCache removeAllObjects];
    }
}

+ (NSFont *)fontForSlot:(VibeFontSlot)slot base:(CGFloat)base bold:(BOOL)bold {
    @synchronized (self) {
        if (!slotCache) {
            slotCache = [NSMutableDictionary new];
        }
        NSString *key = [NSString stringWithFormat:@"%ld-%@",
                (long)slot, fontCacheKey(base, bold)];
        NSFont *cached = slotCache[key];
        if (cached) {
            return cached;
        }
        CGFloat size = base + slotOffset[slot];
        NSFont *font = nil;
        NSString *face = slotFace[slot];
        if (face) {
            font = [NSFont fontWithName:face size:size];
            if (font && bold) {
                NSFont *bolded = [NSFontManager.sharedFontManager convertFont:font
                                                                  toHaveTrait:NSBoldFontMask];
                font = bolded ?: font;
            }
            if (font && (slot == VibeFontSlotInfo || slot == VibeFontSlotPlaylistDuration)) {
                // Times tick every second; a proportional-digit face would
                // jitter them, so ask for the monospaced-digits feature. A
                // face without it ignores the request.
                NSFontDescriptor *mono = [font.fontDescriptor fontDescriptorByAddingAttributes:@{
                    NSFontFeatureSettingsAttribute: @[@{
                        NSFontFeatureTypeIdentifierKey: @(kNumberSpacingType),
                        NSFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector),
                    }],
                }];
                font = [NSFont fontWithDescriptor:mono size:size] ?: font;
            }
        }
        // Different lock objects, so the nested caches cannot deadlock.
        if (!font) {
            font = (slot == VibeFontSlotInfo || slot == VibeFontSlotPlaylistDuration)
                    ? [self fontForNumbers:size bold:bold]
                    : [self font:size bold:bold];
        }
        slotCache[key] = font;
        return font;
    }
}

+ (NSFont *)titleFont:(CGFloat)baseSize {
    return [self fontForSlot:VibeFontSlotTitle base:baseSize bold:NO];
}

+ (NSFont *)artistFont:(CGFloat)baseSize {
    return [self fontForSlot:VibeFontSlotArtist base:baseSize bold:NO];
}

+ (NSFont *)infoFont:(CGFloat)baseSize bold:(BOOL)bold {
    return [self fontForSlot:VibeFontSlotInfo base:baseSize bold:bold];
}

+ (NSFont *)playlistFont:(CGFloat)baseSize {
    return [self fontForSlot:VibeFontSlotPlaylist base:baseSize bold:NO];
}

+ (NSFont *)playlistDurationFont:(CGFloat)baseSize {
    return [self fontForSlot:VibeFontSlotPlaylistDuration base:baseSize bold:NO];
}

@end
