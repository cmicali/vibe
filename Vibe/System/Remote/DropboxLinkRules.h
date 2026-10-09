//
//  DropboxLinkRules.h
//  Vibe
//
//  Open URL's Dropbox share links. LinkRules.h's VibeLinkDirectDownloadURL
//  asks this file. No other link code knows Dropbox. Header-only and
//  Foundation-only, so the macOS suite tests it.
//
//  What Dropbox answers a link, measured on a shared AIFF. dl=1 answers one
//  302 to <id>.dl.dropboxusercontent.com. A range there gets a 206 with
//  Content-Range and an ETag, and the ETag is the version. Its
//  Content-Disposition says filename=unspecified. The name then comes from
//  the link's own path, which has a playable extension. Dropbox answers HEAD
//  with JSON, which is one reason the probe is a GET.
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
