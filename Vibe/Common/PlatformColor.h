//
//  PlatformColor.h
//  Vibe
//
//  #RRGGBB[AA] hex ↔ VibeColor, the persisted form of a stored color. Free
//  functions because the class differs per platform.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

// C linkage: the .mm renderers include this header.
#ifdef __cplusplus
extern "C" {
#endif

// nil for anything but a parseable #RRGGBB or #RRGGBBAA (a leading #
// optional); six digits read as opaque.
VibeColor *_Nullable VibeColorFromHexString(NSString *_Nullable hex);

// #RRGGBB when opaque, #RRGGBBAA otherwise; nil when the color has no RGB
// reading.
NSString *_Nullable VibeHexStringFromColor(VibeColor *_Nullable color);

// A linear sRGB blend `fraction` of the way toward `toward`, at full alpha;
// `color` itself when either has no RGB reading.
VibeColor *VibeColorBlended(VibeColor *color, VibeColor *toward, CGFloat fraction);

// The color at `fraction` of its own alpha, hue untouched.
VibeColor *VibeColorWithScaledAlpha(VibeColor *color, CGFloat fraction);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
