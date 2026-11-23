//
//  VibeBrowserHost.m
//  Vibe (iOS)
//

#import "VibeBrowserHost.h"

#import <objc/runtime.h>

#import "AudioTrackMetadataCache.h"

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

@implementation VibeBrowserRootRow

+ (instancetype)rowWithTitle:(NSString *)title
                       image:(UIImage *)image
                     handler:(void (^)(UIViewController *screen))handler {
    VibeBrowserRootRow *row = [[self alloc] initPrivate];
    row->_title = [title copy];
    row->_image = image;
    row->_handler = [handler copy];
    return row;
}

- (instancetype)initPrivate {
    return [super init];
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

static const void *const kDefaultArtCacheKey = &kDefaultArtCacheKey;

// Each cache opens its own store, which lists the whole metadata cache
// directory when made, so the browser makes one for a host only when asked.
AudioTrackMetadataCache *VibeBrowserArtCache(id<VibeBrowserHost> host) {
    AudioTrackMetadataCache *cache = objc_getAssociatedObject(host, kDefaultArtCacheKey);
    if (!cache) {
        cache = [[AudioTrackMetadataCache alloc] init];
        objc_setAssociatedObject(host, kDefaultArtCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cache;
}
