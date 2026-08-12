//
//  PlatformTypes.h
//  Vibe
//
//  Platform-neutral aliases for UI types that appear in otherwise portable
//  model headers. VibeImage is NSImage on macOS and UIImage elsewhere;
//  implementation files construct the platform class directly.
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
