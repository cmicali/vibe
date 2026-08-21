//
//  PlatformColor.h
//  Vibe
//
//  #RRGGBB hex ↔ VibeColor, the persisted form of a stored color setting —
//  inspectable, cross-platform, `defaults write`-able. Free functions rather
//  than a category because the constructed class differs per platform, the
//  PlatformImage.h precedent.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

// nil for anything but a parseable #RRGGBB (a leading # optional).
VibeColor *_Nullable VibeColorFromHexString(NSString *_Nullable hex);

// #RRGGBB, alpha dropped; nil when the color has no RGB reading.
NSString *_Nullable VibeHexStringFromColor(VibeColor *_Nullable color);

NS_ASSUME_NONNULL_END
