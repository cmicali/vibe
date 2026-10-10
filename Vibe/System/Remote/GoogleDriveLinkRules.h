//
//  GoogleDriveLinkRules.h
//  Vibe
//
//  Open URL's Google Drive share links. LinkRules.h's
//  VibeLinkDirectDownloadURL asks this file. No other link code knows Google
//  Drive. Header-only and Foundation-only, so the macOS suite tests it.
//
//  What Google Drive answers a link, measured on a shared WAV. A range gets a
//  206 with Content-Range. It sends Last-Modified and no ETag. Last-Modified
//  is then the version. The path ends in "download" and names nothing. The
//  name comes from Content-Disposition. A private or over-quota file answers
//  an HTML page. It fails as denied on a 403, and as not audio on a 200.
//  Drive's /u/<n>/ paths and docs.google.com links are not rewritten.
//

#ifndef GoogleDriveLinkRules_h
#define GoogleDriveLinkRules_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A Google Drive link to a file as Google's download address. The file's id
// comes from /file/d/<id>/…, or from the id item of /open or /uc. confirm=t
// skips the virus-scan page a large file gets. A resourcekey item is kept.
// Older shares need it. nil for any other URL. A folder link is not a file
// link, and neither is an id with characters an id never has.
static inline NSURL *_Nullable VibeGoogleDriveLinkDownloadURL(NSURL *url) {
    if (![url.host.lowercaseString isEqualToString:@"drive.google.com"]) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    // Split before decoding: an encoded '/' stays inside its part and fails
    // the id check.
    NSArray<NSString *> *parts = [components.percentEncodedPath componentsSeparatedByString:@"/"];
    NSString *fileID = nil;
    NSString *resourceKey = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"resourcekey"]) resourceKey = item.value;
    }
    if (parts.count >= 4 && [parts[1] isEqualToString:@"file"] && [parts[2] isEqualToString:@"d"]) {
        fileID = parts[3];
    } else if (parts.count == 2 && ([parts[1] isEqualToString:@"open"] || [parts[1] isEqualToString:@"uc"])) {
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"id"]) fileID = item.value;
        }
    }
    NSCharacterSet *idCharacters =
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    if (fileID.length == 0 || [fileID rangeOfCharacterFromSet:idCharacters.invertedSet].location != NSNotFound) {
        return nil;
    }
    NSURLComponents *download = [NSURLComponents componentsWithString:@"https://drive.usercontent.google.com/download"];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithObjects:
        [NSURLQueryItem queryItemWithName:@"id" value:fileID],
        [NSURLQueryItem queryItemWithName:@"export" value:@"download"],
        [NSURLQueryItem queryItemWithName:@"confirm" value:@"t"], nil];
    if (resourceKey.length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"resourcekey" value:resourceKey]];
    }
    download.queryItems = items;
    return download.URL;
}

NS_ASSUME_NONNULL_END

#endif /* GoogleDriveLinkRules_h */
