//
//  Fonts+Theme.h
//  Vibe
//
//  Vibe's five slots (VibeFontSlot, declared with the theme), pushed from the
//  theme. Fonts itself knows no theme.
//

#import "Fonts.h"
#import "AppTheme.h"

@interface Fonts (Theme)

// Pushes every slot's face and size. Info and playlist duration are the
// numeric slots. MainPlayerController.applyStoredFonts runs it before any
// label exists, and again on every Fonts effect.
+ (void)applyThemeFonts:(AppTheme *)theme;

+ (NSFont *)titleFont;
+ (NSFont *)artistFont;
+ (NSFont *)infoFontBold:(BOOL)bold;
// The info readouts' kerning and alignment. No face: each field carries its
// own infoFontBold:.
+ (NSDictionary<NSAttributedStringKey, id> *)infoTextAttributesAligned:(NSTextAlignment)alignment;
+ (NSFont *)playlistFont;
+ (NSFont *)playlistDurationFont;

@end
