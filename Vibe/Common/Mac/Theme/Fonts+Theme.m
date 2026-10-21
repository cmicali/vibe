//
//  Fonts+Theme.m
//  Vibe
//

#import "Fonts+Theme.h"

@implementation Fonts (Theme)

+ (void)applyThemeFonts:(AppTheme *)theme {
    for (NSInteger slot = VibeFontSlotNone + 1; slot < kVibeFontSlotCount; slot++) {
        BOOL numeric = slot == VibeFontSlotInfo || slot == VibeFontSlotPlaylistDuration;
        [self setFace:[theme fontFaceForSlot:(VibeFontSlot)slot]
                 size:[theme fontSizeForSlot:(VibeFontSlot)slot]
              numeric:numeric forSlot:slot];
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

+ (NSDictionary<NSAttributedStringKey, id> *)infoTextAttributesAligned:(NSTextAlignment)alignment {
    NSMutableParagraphStyle *paragraph = [[NSParagraphStyle new] mutableCopy];
    paragraph.alignment = alignment;
    return @{NSKernAttributeName: @(-1.2), NSParagraphStyleAttributeName: paragraph};
}

+ (NSFont *)playlistFont {
    return [self fontForSlot:VibeFontSlotPlaylist bold:NO];
}

+ (NSFont *)playlistDurationFont {
    return [self fontForSlot:VibeFontSlotPlaylistDuration bold:NO];
}

@end
