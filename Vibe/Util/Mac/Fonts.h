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

@end
