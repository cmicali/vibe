//
//  NSString+FormLabel.m
//  Vibe
//

#import "NSString+FormLabel.h"

@implementation NSString (FormLabel)

- (NSString *)vibeFormLabel {
    // whitespaceCharacterSet includes French's no-break space.
    if ([self hasSuffix:@":"] || [self hasSuffix:@"："]) {
        return [[self substringToIndex:self.length - 1]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return self;
}

@end
