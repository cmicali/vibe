//
//  Fonts.m
//  Vibe
//

#import "Fonts.h"

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
    VibeFontSlotMain = 0,
    VibeFontSlotInfo,
    VibeFontSlotPlaylist,
};

// The slots' reference bases — the sizes their reference sites pass — and the
// pushed configuration. All access is under @synchronized(Fonts.class): not
// every caller is on the main thread, same as the caches above.
static const CGFloat kSlotBase[3] = {23, 13, 14};
static NSString *slotFace[3];
static CGFloat slotOffset[3];
static NSMutableDictionary<NSString *, NSFont *> *slotCache;

+ (void)applyThemeFonts:(NSString *)mainFace mainSize:(CGFloat)mainSize
               infoFace:(NSString *)infoFace infoSize:(CGFloat)infoSize
           playlistFace:(NSString *)playlistFace playlistSize:(CGFloat)playlistSize {
    @synchronized (self) {
        slotFace[VibeFontSlotMain] = mainFace.length ? mainFace : nil;
        slotFace[VibeFontSlotInfo] = infoFace.length ? infoFace : nil;
        slotFace[VibeFontSlotPlaylist] = playlistFace.length ? playlistFace : nil;
        slotOffset[VibeFontSlotMain] = mainSize - kSlotBase[VibeFontSlotMain];
        slotOffset[VibeFontSlotInfo] = infoSize - kSlotBase[VibeFontSlotInfo];
        slotOffset[VibeFontSlotPlaylist] = playlistSize - kSlotBase[VibeFontSlotPlaylist];
        [slotCache removeAllObjects];
    }
}

+ (NSFont *)fontForSlot:(VibeFontSlot)slot base:(CGFloat)base bold:(BOOL)bold {
    @synchronized (self) {
        if (!slotCache) {
            slotCache = [NSMutableDictionary new];
        }
        NSString *key = [NSString stringWithFormat:@"%ld-%g%@",
                (long)slot, base, bold ? @"-bold" : @""];
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
            if (font && slot == VibeFontSlotInfo) {
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
        if (!font) {
            font = slot == VibeFontSlotInfo
                    ? [NSFont monospacedDigitSystemFontOfSize:size
                                                       weight:bold ? NSFontWeightBold : NSFontWeightRegular]
                    : [self font:size bold:bold];
        }
        slotCache[key] = font;
        return font;
    }
}

+ (NSFont *)mainFont:(CGFloat)baseSize {
    return [self fontForSlot:VibeFontSlotMain base:baseSize bold:NO];
}

+ (NSFont *)mainFont:(CGFloat)baseSize bold:(BOOL)bold {
    return [self fontForSlot:VibeFontSlotMain base:baseSize bold:bold];
}

+ (NSFont *)infoFont:(CGFloat)baseSize bold:(BOOL)bold {
    return [self fontForSlot:VibeFontSlotInfo base:baseSize bold:bold];
}

+ (NSFont *)playlistFont:(CGFloat)baseSize {
    return [self fontForSlot:VibeFontSlotPlaylist base:baseSize bold:NO];
}

@end
