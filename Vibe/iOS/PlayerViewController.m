//
//  PlayerViewController.m
//  Vibe (iOS)
//

#import "PlayerViewController.h"

@implementation PlayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *placeholder = [[UILabel alloc] init];
    placeholder.text = VibeNotLocalized(@"Vibe");
    placeholder.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    placeholder.textColor = [UIColor secondaryLabelColor];
    placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:placeholder];
    [NSLayoutConstraint activateConstraints:@[
        [placeholder.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [placeholder.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

@end
