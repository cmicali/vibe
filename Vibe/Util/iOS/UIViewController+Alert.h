//
//  UIViewController+Alert.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIViewController (VibeAlert)

// An alert with one OK button, presented by the receiver.
- (void)vibePresentAlertWithTitle:(NSString *)title message:(NSString *)message;

// What an alert goes over: the top of the receiver's presentation stack, the
// add sheet or the card, past one being dismissed.
@property (nonatomic, readonly) UIViewController *vibeTopmostPresenter;

@end

NS_ASSUME_NONNULL_END
