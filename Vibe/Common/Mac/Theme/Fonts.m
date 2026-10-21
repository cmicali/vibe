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
    // Not every caller is on main.
    @synchronized (cache) {
        NSFont *font = cache[key];
        if (!font) {
            font = [NSFont fontWithName:bold ? @"HelveticaNeue-Bold" : @"HelveticaNeue-Medium" size:size];
            if (!font) {
                // Never nil: callers put it straight into attribute
                // dictionaries.
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

#pragma mark Slots

// Slot → @[face, size, numeric]; guarded by @synchronized(Fonts.class), as
// is the resolved cache.
static NSMutableDictionary<NSNumber *, NSArray *> *slotTable;
static NSMutableDictionary<NSString *, NSFont *> *slotCache;

+ (void)setFace:(NSString *)face size:(CGFloat)size numeric:(BOOL)numeric forSlot:(NSInteger)slot {
    @synchronized (self) {
        if (!slotTable) {
            slotTable = [NSMutableDictionary new];
        }
        slotTable[@(slot)] = @[face ?: @"", @(size), @(numeric)];
        [slotCache removeAllObjects];
    }
}

+ (NSFont *)fontForSlot:(NSInteger)slot bold:(BOOL)bold {
    @synchronized (self) {
        if (!slotCache) {
            slotCache = [NSMutableDictionary new];
        }
        NSString *key = [NSString stringWithFormat:@"%ld%@", (long)slot, bold ? @"-bold" : @""];
        NSFont *cached = slotCache[key];
        if (cached) {
            return cached;
        }
        NSArray *entry = slotTable[@(slot)];
        NSString *face = entry[0];
        CGFloat size = [entry[1] doubleValue];
        BOOL numeric = [entry[2] boolValue];
        NSFont *font = nil;
        if (face.length) {
            font = [NSFont fontWithName:face size:size];
            if (font && bold) {
                NSFont *bolded = [NSFontManager.sharedFontManager convertFont:font
                                                                  toHaveTrait:NSBoldFontMask];
                font = bolded ?: font;
            }
            if (font && numeric) {
                // Monospaced digits, so ticking times do not jitter; a face
                // without the feature ignores it.
                NSFontDescriptor *mono = [font.fontDescriptor fontDescriptorByAddingAttributes:@{
                    NSFontFeatureSettingsAttribute: @[@{
                        NSFontFeatureTypeIdentifierKey: @(kNumberSpacingType),
                        NSFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector),
                    }],
                }];
                font = [NSFont fontWithDescriptor:mono size:size] ?: font;
            }
        }
        // The nested caches take their own locks, never this one: no deadlock.
        if (!font) {
            font = numeric ? [self fontForNumbers:size bold:bold] : [self font:size bold:bold];
        }
        slotCache[key] = font;
        return font;
    }
}

@end
