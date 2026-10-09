//
//  DropboxLinkRules.h
//  Vibe
//
//  Open URL's Dropbox share links. LinkRules.h's VibeLinkDirectDownloadURL
//  asks this file. No other link code knows Dropbox. Header-only and
//  Foundation-only, so the macOS suite tests it.
//

#ifndef DropboxLinkRules_h
#define DropboxLinkRules_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A Dropbox share link to a file (/scl/fi/… or /s/…) with dl=1, which
// answers a redirect to the bytes. Its other query items, rlkey among them,
// are kept. nil for any other URL, a folder link included.
static inline NSURL *_Nullable VibeDropboxLinkDownloadURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!([host isEqualToString:@"dropbox.com"] || [host isEqualToString:@"www.dropbox.com"])) return nil;
    NSString *path = url.path;
    if (!([path hasPrefix:@"/scl/fi/"] || [path hasPrefix:@"/s/"])) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isEqualToString:@"dl"]) [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"dl" value:@"1"]];
    components.queryItems = items;
    return components.URL;
}

NS_ASSUME_NONNULL_END

#endif /* DropboxLinkRules_h */
