//
//  UIView+DarkMode.h
//  Vibe (iOS)
//
//  The iOS mirror of NSView+DarkMode, so renderer call sites read the same
//  on both platforms.
//

#import <UIKit/UIKit.h>

@interface UIView (DarkMode)

@property (nonatomic, readonly) BOOL isDark;

@end
