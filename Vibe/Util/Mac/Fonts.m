//
//  Fonts.m
//  Vibe
//

#import "Fonts.h"
#import "AppTheme.h"

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

// The pushed configuration, indexed by VibeFontSlot (AppTheme.h; entry None
// unused). All access is under @synchronized(Fonts.class) — its own lock; the
// caches above each lock their own dictionary.
static NSString *slotFace[kVibeFontSlotCount];
static CGFloat slotSize[kVibeFontSlotCount];
static NSMutableDictionary<NSString *, NSFont *> *slotCache;

// The factory look until the shell pushes the stored theme, so a slot
// resolved before that push is the Vibe theme's font rather than size 0.
+ (void)initialize {
    if (self == Fonts.class) {
        [self applyThemeFonts:[[AppTheme alloc] init]];
    }
}

+ (void)applyThemeFonts:(AppTheme *)theme {
    @synchronized (self) {
        for (NSInteger slot = VibeFontSlotNone + 1; slot < kVibeFontSlotCount; slot++) {
            NSString *face = [theme fontFaceForSlot:(VibeFontSlot)slot];
            slotFace[slot] = face.length ? face : nil;
            slotSize[slot] = [theme fontSizeForSlot:(VibeFontSlot)slot];
        }
        [slotCache removeAllObjects];
    }
}

+ (NSFont *)fontForSlot:(VibeFontSlot)slot bold:(BOOL)bold {
    @synchronized (self) {
        if (!slotCache) {
            slotCache = [NSMutableDictionary new];
        }
        NSString *key = [NSString stringWithFormat:@"%ld%@", (long)slot, bold ? @"-bold" : @""];
        NSFont *cached = slotCache[key];
        if (cached) {
            return cached;
        }
        CGFloat size = slotSize[slot];
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

+ (NSFont *)titleFont {
    return [self fontForSlot:VibeFontSlotTitle bold:NO];
}

+ (NSFont *)artistFont {
    return [self fontForSlot:VibeFontSlotArtist bold:NO];
}

+ (NSFont *)infoFontBold:(BOOL)bold {
    return [self fontForSlot:VibeFontSlotInfo bold:bold];
}

+ (NSFont *)playlistFont {
    return [self fontForSlot:VibeFontSlotPlaylist bold:NO];
}

+ (NSFont *)playlistDurationFont {
    return [self fontForSlot:VibeFontSlotPlaylistDuration bold:NO];
}

@end
