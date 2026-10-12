//
//  UIViewController+Alert.m
//  Vibe (iOS)
//

#import "UIViewController+Alert.h"

#import "VibeStrings.h"

@implementation UIViewController (VibeAlert)

- (void)vibePresentAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_OK style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIViewController *)vibeTopmostPresenter {
    UIViewController *presenter = self;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }
    return presenter;
}

@end
