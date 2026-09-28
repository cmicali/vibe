//
//  Fonts.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AppTheme.h" // VibeFontSlot, and the theme the slots are pushed from

// The app's typography: text is Helvetica Neue; digit displays use
// fontForNumbers: (monospaced digits) so changing values do not jitter.
@interface Fonts : NSObject

+ (NSFont *)font:(CGFloat)size;
+ (NSFont *)font:(CGFloat)size bold:(BOOL)bold;
+ (NSFont *)fontForNumbers:(CGFloat)size;
+ (NSFont *)fontForNumbers:(CGFloat)size bold:(BOOL)bold;

// The themed slots. Util may not read a setting, so the theme is PUSHED here;
// until the first push the slots resolve the factory look. An empty or
// uninstalled face falls back to font: (fontForNumbers: for info and
// duration), so a slot never returns nil. A named info or duration face gains
// monospaced digits.
+ (void)applyThemeFonts:(AppTheme *)theme;

+ (NSFont *)fontForSlot:(VibeFontSlot)slot bold:(BOOL)bold;
+ (NSFont *)titleFont;
+ (NSFont *)artistFont;
+ (NSFont *)infoFontBold:(BOOL)bold;
// The info readouts' kerning and alignment. No face: each field carries its
// own infoFontBold:.
+ (NSDictionary<NSAttributedStringKey, id> *)infoTextAttributesAligned:(NSTextAlignment)alignment;
+ (NSFont *)playlistFont;
+ (NSFont *)playlistDurationFont;

@end
