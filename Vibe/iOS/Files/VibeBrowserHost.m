//
//  VibeBrowserHost.m
//  Vibe (iOS)
//

#import "VibeBrowserHost.h"

@implementation VibeBrowserFolderSource

@synthesize rootURL = _rootURL;
@synthesize title = _title;
@synthesize image = _image;

+ (instancetype)sourceWithRootURL:(NSURL *)rootURL title:(NSString *)title image:(UIImage *)image {
    VibeBrowserFolderSource *source = [[self alloc] initPrivate];
    source->_rootURL = [rootURL copy];
    source->_title = [title copy];
    source->_image = image;
    return source;
}

- (instancetype)initPrivate {
    return [super init];
}

- (NSString *)subtitle {
    return nil;
}

@end

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

void VibeBrowserPresentAlert(UIViewController *screen, id<VibeBrowserHost> host, NSString *title,
                             NSString *message, dispatch_block_t then) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[host label:VibeBrowserLabelOK]
                                              style:UIAlertActionStyleDefault
                                            handler:then ? ^(UIAlertAction *action) { then(); } : nil]];
    [screen presentViewController:alert animated:YES completion:nil];
}
