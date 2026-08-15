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
extern const CGFloat kVibeThumbnailArtDimension;

// The cap for a full-resolution display image. Nothing renders art larger than
// the roughly 300px artwork panel or the 512px dock icon, and decoding straight
// to this size never allocates the original-resolution bitmap, over 50MB.
extern const CGFloat kVibeDisplayArtDimension;

// Decodes image data at a bounded pixel size through ImageIO. Unlike
// initWithData: followed by a resize, this never materializes the full-size
// bitmap. nil for nil data, or data that is not a decodable image. The decode
// can take 10-100ms, so it belongs off the main thread.
VibeImage *_Nullable VibeDecodedImageWithData(NSData *_Nullable data, CGFloat maxPixelSize);

NS_ASSUME_NONNULL_END
