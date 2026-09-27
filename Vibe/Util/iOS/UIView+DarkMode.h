//
//  UIView+DarkMode.h
//  Vibe (iOS)
//
//  The mirror of NSView+DarkMode, so shared call sites read the same.
//

#import <UIKit/UIKit.h>

@interface UIView (DarkMode)

@property (nonatomic, readonly) BOOL isDark;

@end
