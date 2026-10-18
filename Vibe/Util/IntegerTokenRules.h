//
//  IntegerTokenRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A decimal token of digits only, with no sign, space or suffix. NO for an
// empty token, any other character, or a value past NSUIntegerMax, and *out is
// then left as it was.
static inline BOOL VibeParseNonnegativeInteger(NSString *token, NSUInteger *out) {
    if (!token.length) {
        return NO;
    }
    NSUInteger parsed = 0;
    for (NSUInteger index = 0; index < token.length; index++) {
        unichar character = [token characterAtIndex:index];
        if (character < '0' || character > '9') {
            return NO;
        }
        NSUInteger digit = character - '0';
        if (parsed > (NSUIntegerMax - digit) / 10) {
            return NO;
        }
        parsed = parsed * 10 + digit;
    }
    *out = parsed;
    return YES;
}

NS_ASSUME_NONNULL_END
