//
//  DropboxRules.h
//  Vibe (iOS)
//
//  The Dropbox decisions that need no network and no disk: the sign-in's
//  addresses, the wire encodings, how an entry reads, and when a mirror file
//  is current. What every account shares is AccountRules.h. Header-only and
//  Foundation-only so the macOS suite tests it.
//

#ifndef DropboxRules_h
#define DropboxRules_h

#import <Foundation/Foundation.h>
#import "AccountRules.h"
#import "HTTPTransferRules.h"
#import "PlaylistFile.h"

#include <sys/types.h>
#include <time.h>

NS_ASSUME_NONNULL_BEGIN

#define VIBE_DROPBOX_API_BASE     @"https://api.dropboxapi.com/2/"
#define VIBE_DROPBOX_CONTENT_BASE @"https://content.dropboxapi.com/2/"
#define VIBE_DROPBOX_TOKEN_URL    @"https://api.dropboxapi.com/oauth2/token"
#define VIBE_DROPBOX_AUTHORIZE    @"https://www.dropbox.com/oauth2/authorize"
#define VIBE_DROPBOX_SCOPES       @"account_info.read files.metadata.read files.content.read sharing.read"

#pragma mark - OAuth

// The scheme Dropbox accepts for an app without registering it, so nothing
// in the App Console or Info.plist names it.
static inline NSString *VibeDropboxCallbackScheme(NSString *appKey) {
    return [@"db-" stringByAppendingString:appKey];
}

// Sent twice, to authorize and to the code exchange; Dropbox refuses a
// mismatch.
static inline NSString *VibeDropboxRedirectURI(NSString *appKey) {
    return [VibeDropboxCallbackScheme(appKey) stringByAppendingString:@"://2/token"];
}

static inline NSURL *VibeDropboxAuthorizeURL(NSString *appKey,
                                             NSString *codeChallenge,
                                             NSString *state) {
    NSURLComponents *components = [NSURLComponents componentsWithString:VIBE_DROPBOX_AUTHORIZE];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client_id" value:appKey],
        [NSURLQueryItem queryItemWithName:@"response_type" value:@"code"],
        [NSURLQueryItem queryItemWithName:@"code_challenge" value:codeChallenge],
        [NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
        // offline: a refresh token, so a sign-in outlives the 4 h access token.
        [NSURLQueryItem queryItemWithName:@"token_access_type" value:@"offline"],
        [NSURLQueryItem queryItemWithName:@"redirect_uri" value:VibeDropboxRedirectURI(appKey)],
        [NSURLQueryItem queryItemWithName:@"scope" value:VIBE_DROPBOX_SCOPES],
        [NSURLQueryItem queryItemWithName:@"state" value:state],
    ];
    return components.URL;
}

#pragma mark - Wire

// TRAP: the content endpoints take their arguments in the Dropbox-API-Arg
// HEADER, which must be ASCII, so a path holding "é" or "日本" is sent as
// \uXXXX escapes. Raw UTF-8 there fails every non-English filename with a 400.
static inline NSString *_Nullable VibeDropboxAPIArgHeader(NSDictionary *arguments) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:arguments
                                                   options:NSJSONWritingWithoutEscapingSlashes
                                                     error:NULL];
    if (!json) {
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    // The usual argument, an id:, is ASCII already.
    if ([text canBeConvertedToEncoding:NSASCIIStringEncoding]) {
        return text;
    }
    NSMutableString *ascii = [NSMutableString stringWithCapacity:text.length + 16];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < 0x80) {
            [ascii appendString:[NSString stringWithCharacters:&c length:1]];
        }
        else {
            [ascii appendFormat:@"\\u%04x", c];
        }
    }
    return ascii;
}

// Whether a 401's body names this AuthError tag, as its .tag or at the start
// of its summary.
static inline BOOL VibeDropboxIsAuthError(NSInteger status, NSDictionary *_Nullable body, NSString *tag) {
    if (status != 401) {
        return NO;
    }
    id error = body[@"error"];
    NSString *named = [error isKindOfClass:NSDictionary.class] ? error[@".tag"] : nil;
    NSString *summary = body[@"error_summary"];
    return [named isEqualToString:tag] || ([summary isKindOfClass:NSString.class] && [summary hasPrefix:tag]);
}

// A 401 whose body says the access token aged out: refresh and retry once.
// Any other 401 means the grant itself is gone, but for a missing scope.
static inline BOOL VibeDropboxIsExpiredAccessToken(NSInteger status, NSDictionary *_Nullable body) {
    return VibeDropboxIsAuthError(status, body, @"expired_access_token");
}

// A 401 for a call the grant has no scope for. The grant is still good for
// every other call. A sign-in from before a scope the app added lacks it,
// such as sharing.read.
static inline BOOL VibeDropboxIsMissingScope(NSInteger status, NSDictionary *_Nullable body) {
    return VibeDropboxIsAuthError(status, body, @"missing_scope");
}

// The one line an API failure leaves in the log and the error.
static inline NSString *VibeDropboxErrorSummary(NSInteger status, NSDictionary *_Nullable body) {
    NSString *summary = body[@"error_summary"];
    if ([summary isKindOfClass:NSString.class] && summary.length > 0) {
        return summary;
    }
    return [NSString stringWithFormat:@"HTTP %ld", (long)status];
}

#pragma mark - Entries

typedef NS_ENUM(NSInteger, VibeDropboxEntryKind) {
    VibeDropboxEntryKindUnknown = 0,
    VibeDropboxEntryKindFile,
    VibeDropboxEntryKindFolder,
    VibeDropboxEntryKindDeleted,
};

static inline VibeDropboxEntryKind VibeDropboxEntryKindOf(NSDictionary *entry) {
    NSString *tag = entry[@".tag"];
    if ([tag isEqualToString:@"file"]) return VibeDropboxEntryKindFile;
    if ([tag isEqualToString:@"folder"]) return VibeDropboxEntryKindFolder;
    if ([tag isEqualToString:@"deleted"]) return VibeDropboxEntryKindDeleted;
    return VibeDropboxEntryKindUnknown;
}

// A file's size in its metadata, -1 when it names none.
static inline int64_t VibeDropboxSizeOf(NSDictionary *_Nullable metadata) {
    id size = metadata[@"size"];
    return [size isKindOfClass:NSNumber.class] && [size longLongValue] >= 0 ? [size longLongValue] : -1;
}

// The version a file's metadata names, nil when it names none.
static inline NSString *_Nullable VibeDropboxRevOf(NSDictionary *_Nullable metadata) {
    id rev = metadata[@"rev"];
    return [rev isKindOfClass:NSString.class] ? rev : nil;
}

// files/search_v2's answer as entries (the shape list_folder gives), kept
// only for folders and mirrored files other than CUE sheets.
static inline NSArray<NSDictionary *> *VibeDropboxSearchEntries(NSDictionary *_Nullable result,
                                                                 NSSet<NSString *> *playableExtensions) {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSArray *matches = result[@"matches"];
    if (![matches isKindOfClass:NSArray.class]) {
        return entries;
    }
    for (NSDictionary *match in matches) {
        if (![match isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *wrapper = match[@"metadata"];
        NSDictionary *entry = [wrapper isKindOfClass:NSDictionary.class] ? wrapper[@"metadata"] : nil;
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"path_lower"] isKindOfClass:NSString.class]) {
            continue;
        }
        VibeDropboxEntryKind kind = VibeDropboxEntryKindOf(entry);
        NSString *name = entry[@"name"];
        if (kind == VibeDropboxEntryKindFolder
                || (kind == VibeDropboxEntryKindFile && [name isKindOfClass:NSString.class]
                    && VibeAccountNameIsMirrored(name, playableExtensions)
                    && ![PlaylistFile isCueExtension:name.pathExtension.lowercaseString])) {
            [entries addObject:entry];
        }
    }
    return entries;
}

// The Dropbox path of the folder holding `path`; "" for the root's children.
static inline NSString *VibeDropboxParentPath(NSString *path) {
    NSString *parent = path.stringByDeletingLastPathComponent;
    return [parent isEqualToString:@"/"] ? @"" : parent;
}

// Dropbox paths are case-insensitive and only the LAST component of a
// path_display is guaranteed its real case, so a component is matched
// against what is already on disk before a new one is made
// (VibeDropboxLocalName): two spellings of one Dropbox folder must land in
// one local directory.
static inline NSArray<NSString *> *VibeDropboxPathComponents(NSString *path) {
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (component.length > 0) {
            [components addObject:component];
        }
    }
    return components;
}

// The spelling already on disk of a name, else the name itself.
static inline NSString *VibeDropboxLocalName(NSString *name, NSDictionary<NSString *, NSString *> *nameIndex) {
    return nameIndex[VibeAccountIndexKey(name)] ?: name;
}

#pragma mark - Placeholders

// The version check: Dropbox moves server_modified on every upload, so size
// plus mtime names the version the local file holds, placeholder or bytes.
static inline BOOL VibeDropboxLocalMatchesEntry(off_t localSize, time_t localModified,
                                                long long entrySize, time_t entryModified) {
    return entryModified >= 0 && localSize == (off_t)entrySize && localModified == entryModified;
}

NS_ASSUME_NONNULL_END

#endif
