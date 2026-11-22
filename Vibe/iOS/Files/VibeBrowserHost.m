//
//  VibeBrowserHost.m
//  Vibe (iOS)
//

#import "VibeBrowserHost.h"

@implementation VibeBrowserAction

+ (instancetype)actionWithTitle:(NSString *)title
                         symbol:(NSString *)symbol
                        handler:(void (^)(NSArray<NSURL *> *urls, UIViewController *screen))handler {
    return [[self alloc] initWithTitle:title symbol:symbol handler:handler];
}

- (instancetype)initWithTitle:(NSString *)title
                       symbol:(NSString *)symbol
                      handler:(void (^)(NSArray<NSURL *> *urls, UIViewController *screen))handler {
    self = [super init];
    if (self) {
        _title = [title copy];
        _symbol = [symbol copy];
        _handler = [handler copy];
    }
    return self;
}

@end
