//
//  NSString+FormLabel.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSString (FormLabel)

// The string with its form-layout colon dropped, for a grouped row. One rule
// covers French's no-break space and CJK's fullwidth colon.
@property (nonatomic, readonly) NSString *vibeFormLabel;

@end

NS_ASSUME_NONNULL_END
