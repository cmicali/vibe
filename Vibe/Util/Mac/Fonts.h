//
//  Fonts.h
//  Vibe
//

#import <Foundation/Foundation.h>

// The app's typography in one place: all text goes through font:/font:bold:
// (Helvetica Neue), except digit displays (times, bitrate, pitch readout)
// which use fontForNumbers: (monospaced-digit system font) so values don't
// jitter as they change.
@interface Fonts : NSObject

+ (NSFont *)font:(CGFloat)size;
+ (NSFont *)font:(CGFloat)size bold:(BOOL)bold;
+ (NSFont *)fontForNumbers:(CGFloat)size;
+ (NSFont *)fontForNumbers:(CGFloat)size bold:(BOOL)bold;

// The three themed slots. Util may not read a setting, so the theme's choice
// is PUSHED here (applyThemeFonts, which also drops the slot cache) and the
// slot accessors resolve against it. An empty face is the slot's built-in
// font — font:/font:bold: for main and playlist, the monospaced-digit system
// font for info. A face that is not installed falls back the same way, so a
// slot accessor never returns nil. A named info face gains the
// monospaced-digits feature, keeping times jitter-free.
//
// Sizes are offsets in disguise: the stored size is absolute at the slot's
// reference site (title 23, info 13, playlist 14), and a call site passing
// its own base gets base + (stored − reference), which preserves the
// title/artist size hierarchy under any chosen size.
+ (void)applyThemeFonts:(NSString *)mainFace mainSize:(CGFloat)mainSize
               infoFace:(NSString *)infoFace infoSize:(CGFloat)infoSize
           playlistFace:(NSString *)playlistFace playlistSize:(CGFloat)playlistSize;

+ (NSFont *)mainFont:(CGFloat)baseSize;
+ (NSFont *)mainFont:(CGFloat)baseSize bold:(BOOL)bold;
+ (NSFont *)infoFont:(CGFloat)baseSize bold:(BOOL)bold;
+ (NSFont *)playlistFont:(CGFloat)baseSize;

@end
