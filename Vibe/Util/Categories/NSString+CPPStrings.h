
#import <Foundation/Foundation.h>
#import <string>

@interface NSString (cppstring_additions)
+(NSString*) stringWithwstring:(const std::wstring&)string;
+(NSString*) stringWithstring:(const std::string&)string;
-(std::wstring) getwstring;
-(std::string) getstring;
@end
