//
//  PlatformTypes.h
//  Vibe
//
//  Aliases so a portable model header can carry an image or color;
//  implementation files use the platform class directly.
//

#include <TargetConditionals.h>

#if TARGET_OS_OSX
@class NSImage;
typedef NSImage VibeImage;
@class NSColor;
typedef NSColor VibeColor;
#else
@class UIImage;
typedef UIImage VibeImage;
@class UIColor;
typedef UIColor VibeColor;
#endif
