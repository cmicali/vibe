#import "NSString+CPPStrings.h"

@implementation NSString (cppstring_additions)

+ (nullable NSString *)stringWithStdString:(const std::string &)s
{
    // Not initWithUTF8String:c_str(), which truncates at an embedded NUL
    // (corrupt tag frames carry them).
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
}

@end
