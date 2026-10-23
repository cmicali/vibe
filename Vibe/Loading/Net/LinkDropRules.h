//
//  LinkDropRules.h
//  vibe-libs
//
//  What a drop on an app's window, or a paste, opens: which pasteboard
//  types are read, which items are web links, how a .webloc is read, and
//  the order a drop opens in. Header-only and Foundation-only.
//

#ifndef LinkDropRules_h
#define LinkDropRules_h

#import <Foundation/Foundation.h>

#import "LinkRules.h"

NS_ASSUME_NONNULL_BEGIN

// The pasteboard types a drop on an app's window, or a paste, is read for. Finder writes a file URL. A browser's link or address-bar drag writes
// a URL, and often the same link as text. Text from anywhere else may hold
// one link.
static NSString *const kVibeDropTypeFileURL = @"public.file-url";
static NSString *const kVibeDropTypeURL = @"public.url";
static NSString *const kVibeDropTypeText = @"public.utf8-plain-text";

// A .webloc is a small property list. Only this many bytes are read.
static const NSUInteger kVibeLinkWeblocMaxBytes = 64 * 1024;

// An http or https URL with a host. The address rule still decides whether
// it is fetched. Plain http to a public host is a link that fails as
// insecure, before any request.
static inline BOOL VibeLinkIsWebLink(NSURL *_Nullable url) {
    return VibeLinkURLAcceptance(url) != VibeLinkErrorInvalid;
}

static inline BOOL VibeLinkIsWebloc(NSURL *url) {
    return url.isFileURL && [url.pathExtension.lowercaseString isEqualToString:@"webloc"];
}

// What a drop holds, in drop order. Each item is one pasteboard item's
// strings by type. A file URL wins, then a URL, then text. A file is kept as
// it came, since the app pins its path. A URL or text that is no web link
// adds nothing. So does text holding anything but one link.
static inline NSArray<NSURL *> *VibeDropURLsOfItems(NSArray<NSDictionary<NSString *, NSString *> *> *items) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *item in items) {
        NSString *file = item[kVibeDropTypeFileURL];
        if (file) {
            NSURL *url = [NSURL URLWithString:file];
            if (url.isFileURL) [urls addObject:url];
            continue;
        }
        NSURL *link = VibeLinkURLFromString(item[kVibeDropTypeURL] ?: item[kVibeDropTypeText]);
        if (VibeLinkIsWebLink(link)) [urls addObject:link];
    }
    return urls;
}

// What a paste on iOS opens: the first web link among its items, read as a
// drop's are. A file is no link. nil when no item holds one link.
static inline NSURL *_Nullable VibePasteLinkOfItems(NSArray<NSDictionary<NSString *, NSString *> *> *items) {
    for (NSURL *url in VibeDropURLsOfItems(items)) {
        if (!url.isFileURL) return url;
    }
    return nil;
}

// Whether a drop takes the link road: it holds a web link or a .webloc.
static inline BOOL VibeDropHasLinks(NSArray<NSURL *> *urls) {
    for (NSURL *url in urls) {
        if (!url.isFileURL || VibeLinkIsWebloc(url)) return YES;
    }
    return NO;
}

// A .webloc's link: the URL key of its property list, XML or binary. Nil
// when it holds no web link.
static inline NSURL *_Nullable VibeLinkURLOfWebloc(NSData *_Nullable data) {
    if (data.length == 0) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                          format:NULL error:NULL];
    id string = [plist isKindOfClass:NSDictionary.class] ? ((NSDictionary *)plist)[@"URL"] : nil;
    NSURL *url = [string isKindOfClass:NSString.class] ? VibeLinkURLFromString(string) : nil;
    return VibeLinkIsWebLink(url) ? url : nil;
}

// What a drop on the link road opens, in drop order: its files, and its
// links. Each .webloc is swapped for its link. read answers its first bytes,
// or nil. A .webloc with no web link opens nothing. A link the drop already
// holds is not added again, by the store's normalized URL.
static inline NSArray<NSURL *> *VibeDropOpenOrder(NSArray<NSURL *> *urls,
                                                  NSData *_Nullable (^read)(NSURL *webloc)) {
    NSMutableArray<NSURL *> *order = [NSMutableArray array];
    NSMutableSet<NSString *> *links = [NSMutableSet set];
    for (NSURL *dropped in urls) {
        NSURL *url = VibeLinkIsWebloc(dropped) ? VibeLinkURLOfWebloc(read(dropped)) : dropped;
        if (url == nil) continue;
        if (!url.isFileURL) {
            NSString *key = VibeLinkNormalizedURLString(url);
            if ([links containsObject:key]) continue;
            [links addObject:key];
        }
        [order addObject:url];
    }
    return order;
}

NS_ASSUME_NONNULL_END

#endif /* LinkDropRules_h */
