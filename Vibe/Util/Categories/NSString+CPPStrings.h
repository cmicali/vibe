
#import <Foundation/Foundation.h>
#import <string>

@interface NSString (cppstring_additions)
+(NSString*) stringWithstring:(const std::string&)string;
@end
