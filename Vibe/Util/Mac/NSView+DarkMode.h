//
//  NSView+DarkMode.h
//  Vibe
//

#import <Foundation/Foundation.h>

@interface NSAppearance (DarkMode)

// Whether this appearance resolves dark — the one spelling of the
// Aqua/DarkAqua bestMatch fold.
- (BOOL)isDark;

@end

@interface NSView (DarkMode)

- (BOOL)isDark;

@end
