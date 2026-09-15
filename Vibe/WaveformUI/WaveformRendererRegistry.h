//
// The renderer registry: persisted identifier → renderer, plus the style
// resolution fallback chain. One home, shared by the macOS view and the iOS
// scrubber, so the two platforms cannot drift on which styles exist or how an
// unknown persisted identifier falls back.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

@class AudioWaveformRenderer;

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

// The full resolution chain for a persisted style: the given identifier if
// registered, else the app default, else an arbitrary registered style (a
// last resort only — registry order is unspecified).
+ (NSString *)resolveStyleIdentifier:(nullable NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
