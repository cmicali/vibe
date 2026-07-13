#import "NSString+CPPStrings.h"

@implementation NSString (cppstring_additions)

+(NSString*) stringWithstring:(const std::string&)s
{
    NSString* result = [[NSString alloc] initWithUTF8String:s.c_str()];
    return result;
}

@end
