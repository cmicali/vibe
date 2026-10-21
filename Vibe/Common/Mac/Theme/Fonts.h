//
//  Fonts.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

// The app's typography: text is Helvetica Neue; digit displays use
// fontForNumbers: (monospaced digits) so changing values do not jitter.
@interface Fonts : NSObject

+ (NSFont *)font:(CGFloat)size;
+ (NSFont *)font:(CGFloat)size bold:(BOOL)bold;
+ (NSFont *)fontForNumbers:(CGFloat)size;
+ (NSFont *)fontForNumbers:(CGFloat)size bold:(BOOL)bold;

// The slots: a face-and-size table keyed by an integer the app chooses.
// Fonts reads no setting. The app PUSHES each slot before its first read. An
// empty or uninstalled face falls back to font: (fontForNumbers: for a
// numeric slot), so a slot never returns nil. A named numeric face gains
// monospaced digits.
+ (void)setFace:(NSString *)face size:(CGFloat)size numeric:(BOOL)numeric forSlot:(NSInteger)slot;
+ (NSFont *)fontForSlot:(NSInteger)slot bold:(BOOL)bold;

@end
