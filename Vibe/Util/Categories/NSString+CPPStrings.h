
#import <Foundation/Foundation.h>
#import <string>

@interface NSString (cppstring_additions)
// Not stringWithString: — that selector already exists on NSString, and a
// category with the same name would replace it and reinterpret NSString
// arguments as std::string&. nil on invalid UTF-8.
+ (nullable NSString *)stringWithStdString:(const std::string &)string;
@end
