//
//  PlatformImage.h
//  Vibe
//
//  The bounded image decode and pixel sampling. Free functions because the
//  image class differs per platform.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

// The pixel size of a list-row thumbnail.
FOUNDATION_EXPORT const CGFloat kVibeThumbnailArtDimension;

// The cap for a display-size decode, so the original-resolution bitmap is
// never allocated.
FOUNDATION_EXPORT const CGFloat kVibeDisplayArtDimension;

// The longest side of the display-art rendition archived beside a track's
// metadata (640 mac, 1024 iOS). Also the pass-through threshold: art at or
// under it is archived verbatim; larger art is downscaled, aspect preserved.
FOUNDATION_EXPORT const CGFloat kVibeArchivedDisplayArtDimension;

// Decodes at a bounded pixel size without materializing the full-size bitmap;
// nil for nil or undecodable data. 10-100ms, so keep it off the main thread.
FOUNDATION_EXPORT VibeImage *_Nullable VibeDecodedImageWithData(NSData *_Nullable data, CGFloat maxPixelSize);

// PNG for alpha-bearing art, which JPEG would flatten; JPEG otherwise, far
// smaller for photos. ImageIO sniffs either on decode. nil when the image
// cannot be encoded.
FOUNDATION_EXPORT NSData *_Nullable VibeEncodedImageData(VibeImage *image);

// The pixel size from the container header alone; CGSizeZero for nil or
// undecodable data.
FOUNDATION_EXPORT CGSize VibeEncodedImagePixelSize(NSData *_Nullable data);

// The average of the most-populated hue band, weighted by saturation times
// brightness, so a colorful accent beats a large muted background; a
// monochrome image answers its average gray. Fixed 32x32 downsample; nil only
// when the image cannot be rasterized. Callers asking repeatedly memoize.
FOUNDATION_EXPORT VibeColor *_Nullable VibeDominantColorOfImage(VibeImage *_Nullable image);

// Whether the bottom `fraction` reads as dark. Uses mean weighted brightness
// of gamma-encoded sRGB components, not linear-light luminance. Controls use
// this to pick their color. `backdropIsDark` answers when the band has no
// opaque pixels, or the image cannot be rasterized: what shows there is
// whatever is behind the image.
FOUNDATION_EXPORT BOOL VibeImageLowerBandIsDark(VibeImage *_Nullable image, CGFloat fraction, BOOL backdropIsDark);

NS_ASSUME_NONNULL_END
