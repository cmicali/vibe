//
// Persisted identifier → renderer, and the fallback chain: one home, so the
// platforms cannot drift on which styles exist.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

@class AudioWaveformRenderer;
@class CodableAudioWaveform;
@class WaveformTheme;

NS_ASSUME_NONNULL_BEGIN

@interface WaveformRendererRegistry : NSObject

// All registered style identifiers. Order is unspecified.
+ (NSArray<NSString *> *)availableIdentifiers;

// Builds an identifier returned by resolveStyleIdentifier:, including variants
// that share a class. Resolve once, then store and construct that same choice.
+ (AudioWaveformRenderer *)rendererForResolvedIdentifier:(NSString *)identifier
                                         layer:(CALayer *)layer bounds:(CGRect)bounds isDark:(BOOL)isDark;

// Localized display name, falling back to the identifier itself.
+ (NSString *)displayNameForIdentifier:(NSString *)identifier;

+ (BOOL)supportsBarDensityForIdentifier:(NSString *)identifier;
+ (BOOL)supportsBarWidthForIdentifier:(NSString *)identifier;
+ (BOOL)supportsLevelsForIdentifier:(NSString *)identifier;
// A static sample rendered by the actual style and current display settings.
+ (nullable CGImageRef)newPreviewForIdentifier:(NSString *)identifier dark:(BOOL)dark
                                        theme:(WaveformTheme *)theme barDensity:(CGFloat)barDensity
                                     barWidth:(CGFloat)barWidth
                                    normalize:(BOOL)normalize gainDB:(float)gainDB CF_RETURNS_RETAINED;

// A real track's envelope for a consumer that cannot host a renderer (the
// widget, a second process). progress draws the whole envelope in one side of
// the palette: bake 0 and 1, reveal one over the other.
+ (nullable CGImageRef)newImageForCodableWaveform:(CodableAudioWaveform *)waveform
                                       identifier:(NSString *)identifier
                                        pointSize:(CGSize)size scale:(CGFloat)scale
                                         progress:(CGFloat)progress dark:(BOOL)dark
                                            theme:(WaveformTheme *)theme
                                       barDensity:(CGFloat)barDensity barWidth:(CGFloat)barWidth
                                        normalize:(BOOL)normalize
                                           gainDB:(float)gainDB CF_RETURNS_RETAINED;

// The full resolution chain for a persisted style: the given identifier if
// registered, else the app default, else an arbitrary registered style (a
// last resort only — registry order is unspecified).
+ (NSString *)resolveStyleIdentifier:(nullable NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
