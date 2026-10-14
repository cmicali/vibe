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
//  A folder link (/scl/fo/ or /sh/) has no documented listing without an
//  account. Its share page lists it with a form POST to
//  /list_shared_link_folder_entries, which is undocumented and may change
//  without notice. The form carries the link's key, secure hash, type and
//  rlkey, the folder below the share's root, and the t cookie the page set.
//  The answer is JSON: entries, each with filename, bytes, href and is_dir,
//  and a voucher for the next page. Read from JDownloader's maintained
//  crawler (DropBoxComCrawler.java), not yet run against a real link. Each
//  file plays from its href with dl=1, as a file link does. Its bytes are on
//  the same content host, so a range there is assumed to get a 206.
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

#pragma mark - Folder links

// The page a folder link's listing is sent to, on the link's own host.
static NSString *const kVibeDropboxFolderListingURL = @"https://www.dropbox.com/list_shared_link_folder_entries";

// An https address on dropbox.com or www.dropbox.com.
static inline BOOL VibeDropboxLinkHostIsDropbox(NSURL *_Nullable url) {
    NSString *host = url.host.lowercaseString;
    return [url.scheme.lowercaseString isEqualToString:@"https"]
        && ([host isEqualToString:@"dropbox.com"] || [host isEqualToString:@"www.dropbox.com"]);
}

// A folder link's share token: {linkKey, secureHash, linkType, subPath,
// rlkey}. The type is "c" for /scl/fo/ and "s" for /sh/. subPath is the
// folder below the share's root that the link names, percent-decoded, ""
// for the root. rlkey is left out when the link has none. nil for any other
// URL, a file link included, and for a key or hash with characters one
// never has.
static inline NSDictionary<NSString *, NSString *> *_Nullable VibeDropboxFolderLinkToken(NSURL *_Nullable url) {
    if (!VibeDropboxLinkHostIsDropbox(url)) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    // Split before decoding: an encoded '/' belongs to its name.
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [components.percentEncodedPath componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part];
    }
    NSString *type = nil;
    NSUInteger key = 0;
    if (parts.count >= 4 && [parts[0] isEqualToString:@"scl"] && [parts[1] isEqualToString:@"fo"]) {
        type = @"c";
        key = 2;
    } else if (parts.count >= 3 && [parts[0] isEqualToString:@"sh"]) {
        type = @"s";
        key = 1;
    } else {
        return nil;
    }
    NSCharacterSet *tokenCharacters =
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    for (NSString *part in @[parts[key], parts[key + 1]]) {
        if ([part rangeOfCharacterFromSet:tokenCharacters.invertedSet].location != NSNotFound) return nil;
    }
    NSMutableArray<NSString *> *below = [NSMutableArray array];
    for (NSString *part in [parts subarrayWithRange:NSMakeRange(key + 2, parts.count - key - 2)]) {
        NSString *decoded = part.stringByRemovingPercentEncoding;
        if (decoded.length == 0 || [decoded containsString:@"/"]) return nil;
        [below addObject:decoded];
    }
    NSMutableDictionary<NSString *, NSString *> *token = [@{
        @"linkKey": parts[key], @"secureHash": parts[key + 1], @"linkType": type,
        @"subPath": [below componentsJoinedByString:@"/"],
    } mutableCopy];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"rlkey"] && item.value.length > 0) token[@"rlkey"] = item.value;
    }
    return token;
}

// The folder link Vibe keeps: https://www.dropbox.com, its type's path to the
// folder, and rlkey as its only query item. The same folder typed with dl=0,
// dl=1 or another host spelling is one link.
static inline NSURL *_Nullable VibeDropboxFolderLinkURL(NSDictionary<NSString *, NSString *> *token) {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.dropbox.com"];
    NSString *type = [token[@"linkType"] isEqualToString:@"s"] ? @"/sh/" : @"/scl/fo/";
    NSMutableString *path = [NSMutableString stringWithFormat:@"%@%@/%@", type, token[@"linkKey"], token[@"secureHash"]];
    for (NSString *name in [token[@"subPath"] componentsSeparatedByString:@"/"]) {
        if (name.length > 0) [path appendFormat:@"/%@", name];
    }
    components.path = path;
    if (token[@"rlkey"].length > 0) {
        components.queryItems = @[[NSURLQueryItem queryItemWithName:@"rlkey" value:token[@"rlkey"]]];
    }
    return components.URL;
}

// A listed file's address: its href's path on www.dropbox.com, with rlkey
// and dl=1 as its only query items. The href's rlkey wins over the folder's.
// Any other item, such as a page's st, would make the same file another link
// at every listing, and its download would be lost.
static inline NSURL *_Nullable VibeDropboxFolderFileURL(NSURL *href, NSString *_Nullable rlkey) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:href resolvingAgainstBaseURL:NO];
    NSString *key = rlkey;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"rlkey"] && item.value.length > 0) key = item.value;
    }
    components.host = @"www.dropbox.com";
    components.fragment = nil;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    if (key.length > 0) [items addObject:[NSURLQueryItem queryItemWithName:@"rlkey" value:key]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"dl" value:@"1"]];
    components.queryItems = items;
    return components.URL;
}

// One form value, as a form sends it: every byte but the unreserved ones
// percent-encoded.
static inline NSString *VibeDropboxFormValue(NSString *value) {
    NSCharacterSet *unreserved =
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:unreserved] ?: @"";
}

// The share page's form for one page of the entries of the folder a token
// names. t is the cookie the page set. voucher is the last page's
// next_request_voucher, nil for the first.
static inline NSData *VibeDropboxFolderListingBody(NSDictionary<NSString *, NSString *> *token,
                                                   NSString *t,
                                                   NSString *_Nullable voucher) {
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    void (^add)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
        [fields addObject:[NSString stringWithFormat:@"%@=%@", name, VibeDropboxFormValue(value)]];
    };
    add(@"is_xhr", @"true");
    add(@"link_key", token[@"linkKey"] ?: @"");
    add(@"link_type", token[@"linkType"] ?: @"");
    add(@"secure_hash", token[@"secureHash"] ?: @"");
    add(@"sub_path", token[@"subPath"] ?: @"");
    if (token[@"rlkey"].length > 0) add(@"rlkey", token[@"rlkey"]);
    if (voucher.length > 0) add(@"voucher", voucher);
    add(@"t", t);
    return [[fields componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
}

// A page of a folder's listing as entries, in the page's order. A file is
// {name, size, url}, and a folder {name, folder: YES, token}. A file's url
// is VibeDropboxFolderFileURL's. A folder's token is its href's, with the
// listed folder's rlkey when the href has none. modified, the entry's ts in Unix
// seconds, is added when the page states it. An entry missing any of these,
// or naming another host or another share, is left out. *voucher is the
// next page's, nil after the last page. *name is the listed folder's own
// name, when the page states one. nil for an answer with no list of entries.
static inline NSArray<NSDictionary *> *_Nullable VibeDropboxFolderListingEntries(
        id _Nullable answer, NSDictionary<NSString *, NSString *> *token,
        NSString *_Nullable *_Nullable voucher, NSString *_Nullable *_Nullable name) {
    if (voucher != NULL) *voucher = nil;
    if (name != NULL) *name = nil;
    NSDictionary *page = [answer isKindOfClass:NSDictionary.class] ? answer : nil;
    NSArray *listed = [page[@"entries"] isKindOfClass:NSArray.class] ? page[@"entries"] : nil;
    if (!listed) return nil;
    NSURL *base = [NSURL URLWithString:@"https://www.dropbox.com"];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (id item in listed) {
        NSDictionary *entry = [item isKindOfClass:NSDictionary.class] ? item : nil;
        NSString *filename = [entry[@"filename"] isKindOfClass:NSString.class] ? entry[@"filename"] : nil;
        NSString *href = [entry[@"href"] isKindOfClass:NSString.class] ? entry[@"href"] : nil;
        NSURL *url = href ? [NSURL URLWithString:href relativeToURL:base].absoluteURL : nil;
        if (filename.length == 0 || [filename containsString:@"/"] || !VibeDropboxLinkHostIsDropbox(url)) continue;
        if ([entry[@"is_dir"] isKindOfClass:NSNumber.class] && [entry[@"is_dir"] boolValue]) {
            NSMutableDictionary<NSString *, NSString *> *folder = [VibeDropboxFolderLinkToken(url) mutableCopy];
            if (![folder[@"linkKey"] isEqualToString:token[@"linkKey"]] || folder[@"subPath"].length == 0) continue;
            if (!folder[@"rlkey"] && token[@"rlkey"]) folder[@"rlkey"] = token[@"rlkey"];
            [entries addObject:@{@"name": filename, @"folder": @YES, @"token": folder}];
            continue;
        }
        id bytes = entry[@"bytes"];
        NSURL *download = VibeDropboxFolderFileURL(url, token[@"rlkey"]);
        if (![bytes isKindOfClass:NSNumber.class] || [bytes longLongValue] < 0 || !download) continue;
        NSMutableDictionary *file = [@{@"name": filename, @"size": bytes, @"url": download} mutableCopy];
        id ts = entry[@"ts"];
        if ([ts isKindOfClass:NSNumber.class] && [ts longLongValue] > 0) file[@"modified"] = @([ts longLongValue]);
        [entries addObject:file];
    }
    id more = page[@"has_more_entries"];
    id next = page[@"next_request_voucher"];
    if (voucher != NULL && [more isKindOfClass:NSNumber.class] && [more boolValue]
            && [next isKindOfClass:NSString.class] && [next length] > 0) {
        *voucher = next;
    }
    if (name != NULL) {
        id folder = page[@"folder"];
        id title = [folder isKindOfClass:NSDictionary.class] ? folder[@"filename"] : nil;
        if ([title isKindOfClass:NSString.class] && [title length] > 0) *name = title;
    }
    return entries;
}

NS_ASSUME_NONNULL_END

#endif /* DropboxLinkRules_h */
