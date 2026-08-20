//
//  PlatformImage.h
//  Vibe
//
//  The bounded image decode, in platform-neutral terms. It is the companion to
//  PlatformTypes.h: that header names VibeImage, this one builds one.
//
//  It is a free function rather than a category because there is no single
//  foreign class to hang it on — the constructed class is NSImage or UIImage
//  depending on the target — and because it constructs rather than adds
//  behavior to an instance.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

// The pixel size for a playlist-cell thumbnail, generous for Retina at typical
// row heights.
FOUNDATION_EXPORT const CGFloat kVibeThumbnailArtDimension;

// The cap for a full-resolution display image. Nothing renders art larger than
// the roughly 300px artwork panel or the 512px dock icon, and decoding straight
// to this size never allocates the original-resolution bitmap, over 50MB.
FOUNDATION_EXPORT const CGFloat kVibeDisplayArtDimension;

// The longest side of the display-art rendition archived beside a track's
// metadata (the macOS header's decode source). Doubles as the pass-through
// threshold: original art at or under it is archived verbatim, with no decode
// and no recompression; only larger art is downscaled to this and re-encoded.
// Aspect is always preserved — the square crop is display-time policy.
FOUNDATION_EXPORT const CGFloat kVibeArchivedDisplayArtDimension;

// Decodes image data at a bounded pixel size through ImageIO. Unlike
// initWithData: followed by a resize, this never materializes the full-size
// bitmap. nil for nil data, or data that is not a decodable image. The decode
// can take 10-100ms, so it belongs off the main thread.
FOUNDATION_EXPORT VibeImage *_Nullable VibeDecodedImageWithData(NSData *_Nullable data, CGFloat maxPixelSize);

NS_ASSUME_NONNULL_END
