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
//  A folder link (/drive/folders/<id>) is listed through the Drive API's
//  files.list, with the app's API key and no account. That reaches a folder
//  shared with anyone who has the link. The key is VibeGoogleDriveAPIKey in
//  Info.plist. The API is told the bundle id, so a key restricted to Vibe's
//  bundle id is accepted. An older share needs its resource key, which a
//  request names in X-Goog-Drive-Resource-Keys. Each file plays from the
//  download address a file link gets. Read from Google's API reference, not
//  yet run against a real folder.
//

#ifndef GoogleDriveLinkRules_h
#define GoogleDriveLinkRules_h

#import <Foundation/Foundation.h>

#import "HTTPTransferRules.h"

NS_ASSUME_NONNULL_BEGIN

// Whether a value has only the characters a Drive id has.
static inline BOOL VibeGoogleDriveIsID(NSString *_Nullable value) {
    NSCharacterSet *idCharacters =
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    return value.length > 0 && [value rangeOfCharacterFromSet:idCharacters.invertedSet].location == NSNotFound;
}

// The download address of a Drive file by its id. confirm=t skips the
// virus-scan page a large file gets. A resource key is kept. Older shares
// need it.
static inline NSURL *_Nullable VibeGoogleDriveDownloadURL(NSString *fileID, NSString *_Nullable resourceKey) {
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

// A Google Drive link to a file as its download address
// (VibeGoogleDriveDownloadURL). The file's id comes from /file/d/<id>/…, or
// from the id item of /open or /uc. A resourcekey item is kept. nil for any
// other URL. A folder link is not a file link, and neither is an id with
// characters an id never has.
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
    return VibeGoogleDriveIsID(fileID) ? VibeGoogleDriveDownloadURL(fileID, resourceKey) : nil;
}

#pragma mark - Folder links

// A Drive folder's mimeType. The account's rules read it too.
static NSString *const kVibeGoogleDriveFolderType = @"application/vnd.google-apps.folder";

// A Google Drive folder link: {id, resourceKey}, the resource key left out
// when the link has none. /drive/folders/<id>, with /u/<n>/ or /mobile/
// before folders, as a browser or the app shares it. nil for any other URL.
static inline NSDictionary<NSString *, NSString *> *_Nullable VibeGoogleDriveFolderLink(NSURL *_Nullable url) {
    if (![url.scheme.lowercaseString isEqualToString:@"https"]
            || ![url.host.lowercaseString isEqualToString:@"drive.google.com"]) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [components.percentEncodedPath componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part];
    }
    NSUInteger folders = [parts indexOfObject:@"folders"];
    if (parts.count < 3 || ![parts[0] isEqualToString:@"drive"] || folders == NSNotFound || folders + 1 >= parts.count
            || !VibeGoogleDriveIsID(parts[folders + 1])) return nil;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    for (NSUInteger i = 1; i < folders; i++) {
        BOOL user = [parts[i] isEqualToString:@"u"] || [parts[i] isEqualToString:@"mobile"]
            || (i > 1 && [parts[i - 1] isEqualToString:@"u"]
                && [parts[i] rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound);
        if (!user) return nil;
    }
    NSMutableDictionary<NSString *, NSString *> *folder = [@{@"id": parts[folders + 1]} mutableCopy];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"resourcekey"] && item.value.length > 0) folder[@"resourceKey"] = item.value;
    }
    return folder;
}

// The folder link Vibe keeps: /drive/folders/<id>, with its resourcekey as
// its only query item.
static inline NSURL *_Nullable VibeGoogleDriveFolderLinkURL(NSDictionary<NSString *, NSString *> *folder) {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://drive.google.com"];
    components.path = [@"/drive/folders/" stringByAppendingString:folder[@"id"] ?: @""];
    if (folder[@"resourceKey"].length > 0) {
        components.queryItems = @[[NSURLQueryItem queryItemWithName:@"resourcekey" value:folder[@"resourceKey"]]];
    }
    return components.URL;
}

// files.get of the folder: its name and its type, with the app's key.
static inline NSURL *_Nullable VibeGoogleDriveFolderMetadataURL(NSString *folderID, NSString *apiKey) {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.googleapis.com/drive/v3/files"];
    components.path = [components.path stringByAppendingFormat:@"/%@", folderID];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"fields" value:@"id,name,mimeType"],
        [NSURLQueryItem queryItemWithName:@"supportsAllDrives" value:@"true"],
        [NSURLQueryItem queryItemWithName:@"key" value:apiKey],
    ];
    return components.URL;
}

// files.list of one page of the folder's children, with the app's key:
// folders first, then by name as people sort, a thousand to a page.
// pageToken is the last page's nextPageToken, nil for the first.
static inline NSURL *_Nullable VibeGoogleDriveFolderListURL(NSString *folderID, NSString *apiKey,
                                                           NSString *_Nullable pageToken) {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.googleapis.com/drive/v3/files"];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithObjects:
        [NSURLQueryItem queryItemWithName:@"q" value:[NSString stringWithFormat:@"'%@' in parents and trashed = false",
                                                                                 folderID]],
        [NSURLQueryItem queryItemWithName:@"fields"
                                    value:@"nextPageToken,files(id,name,mimeType,size,modifiedTime,resourceKey)"],
        [NSURLQueryItem queryItemWithName:@"orderBy" value:@"folder,name_natural"],
        [NSURLQueryItem queryItemWithName:@"pageSize" value:@"1000"],
        [NSURLQueryItem queryItemWithName:@"supportsAllDrives" value:@"true"],
        [NSURLQueryItem queryItemWithName:@"includeItemsFromAllDrives" value:@"true"],
        [NSURLQueryItem queryItemWithName:@"key" value:apiKey], nil];
    if (pageToken.length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"pageToken" value:pageToken]];
    }
    components.queryItems = items;
    return components.URL;
}

// X-Goog-Drive-Resource-Keys for a request about the folder: "<id>/<key>",
// nil when it has no resource key.
static inline NSString *_Nullable VibeGoogleDriveResourceKeysHeader(NSDictionary<NSString *, NSString *> *folder) {
    return folder[@"resourceKey"].length > 0 ? [NSString stringWithFormat:@"%@/%@", folder[@"id"], folder[@"resourceKey"]]
                                             : nil;
}

// An RFC 3339 time, as Drive states one, in Unix seconds. -1 for none.
static inline long long VibeGoogleDriveParseTime(id _Nullable text) {
    if (![text isKindOfClass:NSString.class]) return -1;
    static NSISO8601DateFormatter *fractional;
    static NSISO8601DateFormatter *whole;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fractional = [[NSISO8601DateFormatter alloc] init];
        fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        whole = [[NSISO8601DateFormatter alloc] init];
        whole.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    NSDate *date = [fractional dateFromString:text] ?: [whole dateFromString:text];
    return date ? (long long)floor(date.timeIntervalSince1970) : -1;
}

// A page of a folder's children as entries, in the page's order. A file is
// {name, size, url, modified?}: url is its download address, and modified is
// its modifiedTime in Unix seconds. A folder is {name, folder: {id,
// resourceKey}}, the folder link's parts for its own listing. A Google Docs
// file, a shortcut, and an entry missing its id, its name, or a file's size
// are left out. *next is the next page's token, nil after the last page. nil
// for an answer with no list of files.
static inline NSArray<NSDictionary *> *_Nullable VibeGoogleDriveFolderListingEntries(
        id _Nullable answer, NSString *_Nullable *_Nullable next) {
    if (next != NULL) *next = nil;
    NSDictionary *page = [answer isKindOfClass:NSDictionary.class] ? answer : nil;
    NSArray *listed = [page[@"files"] isKindOfClass:NSArray.class] ? page[@"files"] : nil;
    if (!listed) return nil;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (id item in listed) {
        NSDictionary *file = [item isKindOfClass:NSDictionary.class] ? item : nil;
        NSString *fileID = [file[@"id"] isKindOfClass:NSString.class] ? file[@"id"] : nil;
        NSString *name = [file[@"name"] isKindOfClass:NSString.class] ? file[@"name"] : nil;
        NSString *type = [file[@"mimeType"] isKindOfClass:NSString.class] ? file[@"mimeType"] : @"";
        NSString *resourceKey = [file[@"resourceKey"] isKindOfClass:NSString.class] ? file[@"resourceKey"] : nil;
        if (!VibeGoogleDriveIsID(fileID) || name.length == 0 || [name containsString:@"/"]) continue;
        if ([type isEqualToString:kVibeGoogleDriveFolderType]) {
            NSMutableDictionary *folder = [@{@"id": fileID} mutableCopy];
            folder[@"resourceKey"] = resourceKey.length > 0 ? resourceKey : nil;
            [entries addObject:@{@"name": name, @"folder": folder}];
            continue;
        }
        long long size = [file[@"size"] isKindOfClass:NSString.class] ? VibeHTTPParseLength(file[@"size"])
                       : [file[@"size"] isKindOfClass:NSNumber.class] ? [file[@"size"] longLongValue] : -1;
        NSURL *url = VibeGoogleDriveDownloadURL(fileID, resourceKey);
        if ([type hasPrefix:@"application/vnd.google-apps."] || size < 0 || !url) continue;
        NSMutableDictionary *entry = [@{@"name": name, @"size": @(size), @"url": url} mutableCopy];
        long long modified = VibeGoogleDriveParseTime(file[@"modifiedTime"]);
        if (modified > 0) entry[@"modified"] = @(modified);
        [entries addObject:entry];
    }
    id token = page[@"nextPageToken"];
    if (next != NULL && [token isKindOfClass:NSString.class] && [token length] > 0) *next = token;
    return entries;
}

NS_ASSUME_NONNULL_END

#endif /* GoogleDriveLinkRules_h */
