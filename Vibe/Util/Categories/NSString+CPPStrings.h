
#import <Foundation/Foundation.h>
#import <string>

@interface NSString (cppstring_additions)
// Not stringWithString:, which a category would replace, reading NSString
// arguments as std::string&. nil on invalid UTF-8.
+ (nullable NSString *)stringWithStdString:(const std::string &)string;
@end
