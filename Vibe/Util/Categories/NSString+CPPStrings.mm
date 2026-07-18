#import "NSString+CPPStrings.h"

@implementation NSString (cppstring_additions)

+ (nullable NSString *)stringWithStdString:(const std::string &)s
{
    // initWithBytes:length:, not initWithUTF8String:c_str() — the C-string
    // path truncates at an embedded NUL (corrupt tag frames contain them).
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
}

@end
