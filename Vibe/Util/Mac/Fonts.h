//
//  Fonts.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AppTheme.h" // VibeFontSlot, and the theme the slots are pushed from

// The app's typography in one place: all text goes through font:/font:bold:
// (Helvetica Neue), except digit displays (times, bitrate, pitch readout)
// which use fontForNumbers: (monospaced-digit system font) so values don't
// jitter as they change.
@interface Fonts : NSObject

+ (NSFont *)font:(CGFloat)size;
+ (NSFont *)font:(CGFloat)size bold:(BOOL)bold;
+ (NSFont *)fontForNumbers:(CGFloat)size;
+ (NSFont *)fontForNumbers:(CGFloat)size bold:(BOOL)bold;

// The five themed slots. Util may not read a setting, so the theme's choice
// is PUSHED here (applyThemeFonts, which also drops the slot cache) and the
// slot accessors resolve against it, at the theme's size for the slot; until
// the first push they resolve the factory look. An empty face is the slot's
// built-in font — font:/font:bold: for title and playlist, the
// monospaced-digit system font for info. A face that is not installed falls
// back the same way, so a slot accessor never returns nil. A named info face
// gains the monospaced-digits feature, keeping times jitter-free.
+ (void)applyThemeFonts:(AppTheme *)theme;

+ (NSFont *)fontForSlot:(VibeFontSlot)slot bold:(BOOL)bold;
+ (NSFont *)titleFont;
+ (NSFont *)artistFont;
+ (NSFont *)infoFontBold:(BOOL)bold;
+ (NSFont *)playlistFont;
+ (NSFont *)playlistDurationFont;

@end
