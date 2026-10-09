//
//  DropboxRules.h
//  Vibe (iOS)
//
//  The Dropbox decisions that need no network and no disk: the PKCE pieces,
//  the wire encodings, how an entry reads, and when a mirror file is a
//  placeholder. Header-only and Foundation-only so the macOS suite tests it.
//

#ifndef DropboxRules_h
#define DropboxRules_h

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

#import "HTTPTransferRules.h"
#import "PlaylistFile.h"
#import "SettingsRules.h"

#include <sys/types.h>
#include <time.h>

NS_ASSUME_NONNULL_BEGIN

#define VIBE_DROPBOX_API_BASE     @"https://api.dropboxapi.com/2/"
#define VIBE_DROPBOX_CONTENT_BASE @"https://content.dropboxapi.com/2/"
#define VIBE_DROPBOX_TOKEN_URL    @"https://api.dropboxapi.com/oauth2/token"
#define VIBE_DROPBOX_AUTHORIZE    @"https://www.dropbox.com/oauth2/authorize"
#define VIBE_DROPBOX_SCOPES       @"account_info.read files.metadata.read files.content.read"

#pragma mark - OAuth

// RFC 7636 appendix A: base64url, no padding.
static inline NSString *VibeDropboxBase64URL(NSData *data) {
    NSString *base64 = [data base64EncodedStringWithOptions:0];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [base64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

// S256: base64url(SHA-256(ASCII verifier)).
static inline NSString *VibeDropboxCodeChallenge(NSString *verifier) {
    NSData *ascii = [verifier dataUsingEncoding:NSASCIIStringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(ascii.bytes, (CC_LONG)ascii.length, digest);
    return VibeDropboxBase64URL([NSData dataWithBytes:digest length:sizeof digest]);
}

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

// The code from the redirect, or nil with the reason. A state that does not
// match the one sent is refused: the redirect did not come from our request.
static inline NSString *_Nullable VibeDropboxAuthorizationCode(NSURL *callback,
                                                               NSString *expectedState,
                                                               NSString *_Nullable *_Nullable reason) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:callback
                                             resolvingAgainstBaseURL:NO];
    NSString *code = nil, *state = nil, *error = nil, *description = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"code"]) code = item.value;
        else if ([item.name isEqualToString:@"state"]) state = item.value;
        else if ([item.name isEqualToString:@"error"]) error = item.value;
        else if ([item.name isEqualToString:@"error_description"]) description = item.value;
    }
    if (error.length > 0 || code.length == 0) {
        if (reason) {
            *reason = description ?: error ?: @"no authorization code";
        }
        return nil;
    }
    if (![state isEqualToString:expectedState]) {
        if (reason) {
            *reason = @"state mismatch";
        }
        return nil;
    }
    return code;
}

// application/x-www-form-urlencoded, as the token endpoint takes it.
static inline NSData *VibeDropboxFormBody(NSDictionary<NSString *, NSString *> *fields) {
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-._~"];
    NSMutableArray<NSString *> *pairs = [NSMutableArray arrayWithCapacity:fields.count];
    for (NSString *key in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *value = [fields[key] stringByAddingPercentEncodingWithAllowedCharacters:allowed];
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    return [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
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

// A 401 whose body says the access token aged out: refresh and retry once.
// Any other 401 means the grant itself is gone.
static inline BOOL VibeDropboxIsExpiredAccessToken(NSInteger status, NSDictionary *_Nullable body) {
    if (status != 401) {
        return NO;
    }
    id error = body[@"error"];
    NSString *tag = [error isKindOfClass:NSDictionary.class] ? error[@".tag"] : nil;
    NSString *summary = body[@"error_summary"];
    return [tag isEqualToString:@"expired_access_token"]
            || ([summary isKindOfClass:NSString.class] && [summary hasPrefix:@"expired_access_token"]);
}

// The OAuth error a refresh gets once the grant is revoked. Any other 400 (a
// captive portal, a proxy) must not unlink, which deletes every download.
static inline BOOL VibeDropboxIsRevokedGrant(NSInteger status, NSDictionary *_Nullable body) {
    return status == 400 && [body[@"error"] isEqual:@"invalid_grant"];
}

// The shared rule, under the name DropboxRulesTests checks.
static inline NSTimeInterval VibeDropboxRetryDelay(NSInteger status, NSString *_Nullable retryAfter) {
    return VibeHTTPRetryDelay(status, retryAfter);
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

// Dropbox's timestamps are UTC to the second ("2015-05-12T15:50:38Z"); -1 for
// anything else. strptime, not a date formatter: called per entry, per thread.
static inline time_t VibeDropboxParseTimestamp(NSString *_Nullable text) {
    if (![text isKindOfClass:NSString.class]) {
        return -1;
    }
    struct tm parts = {0};
    const char *end = strptime(text.UTF8String, "%Y-%m-%dT%H:%M:%SZ", &parts);
    if (!end || *end != '\0') {
        return -1;
    }
    return timegm(&parts);
}

// Which entries the mirror keeps: playable audio, and the CUE sheets the
// listing reads beside it. Everything else costs a placeholder for nothing.
static inline BOOL VibeDropboxNameIsMirrored(NSString *name, NSSet<NSString *> *playableExtensions) {
    if ([name hasPrefix:@"."]) {
        return NO;
    }
    NSString *extension = name.pathExtension.lowercaseString;
    return [PlaylistFile isPlaylistExtension:extension] || [playableExtensions containsObject:extension];
}

// files/search_v2's answer as entries (the shape list_folder gives), kept
// only when the mirror could hold them: folders, and mirrored files.
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
                    && VibeDropboxNameIsMirrored(name, playableExtensions)
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

// TRAP: a file URL's path comes back decomposed (NFD: "e" plus a combining
// accent) whatever was written, while Dropbox keeps the name as uploaded,
// usually composed. A name read back from disk is never sent as a Dropbox
// path; the directory index holds what Dropbox said, keyed by this form.
static inline NSString *VibeDropboxIndexKey(NSString *name) {
    return name.precomposedStringWithCanonicalMapping.lowercaseString;
}

// A directory's names by VibeDropboxIndexKey, built once per listing.
static inline NSDictionary<NSString *, NSString *> *VibeDropboxNameIndex(NSArray<NSString *> *names) {
    NSMutableDictionary<NSString *, NSString *> *index = [NSMutableDictionary dictionaryWithCapacity:names.count];
    for (NSString *name in names) {
        index[VibeDropboxIndexKey(name)] = name;
    }
    return index;
}

// Dropbox paths are case-insensitive and only the LAST component of a
// path_display is guaranteed its real case, so a component is matched
// against what is already on disk before a new one is made: two spellings of
// one Dropbox folder must land in one local directory.
static inline NSString *VibeDropboxLocalName(NSString *component,
                                             NSDictionary<NSString *, NSString *> *nameIndex) {
    return nameIndex[VibeDropboxIndexKey(component)] ?: component;
}

static inline NSArray<NSString *> *VibeDropboxPathComponents(NSString *path) {
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (component.length > 0) {
            [components addObject:component];
        }
    }
    return components;
}

#pragma mark - Placeholders

// The version check: Dropbox moves server_modified on every upload, so size
// plus mtime names the version the local file holds, placeholder or bytes.
static inline BOOL VibeDropboxLocalMatchesEntry(off_t localSize, time_t localModified,
                                                long long entrySize, time_t entryModified) {
    return entryModified >= 0 && localSize == (off_t)entrySize && localModified == entryModified;
}

#pragma mark - Downloads

// The sizes the downloads may reach before the oldest go back to
// placeholders, the choices offered, smallest first. 10 GB, an album or two
// hundred, which a phone can spare, is the default.
static const NSInteger kVibeDropboxDownloadBudgets[] = {
    1000L * 1000 * 1000, 2000L * 1000 * 1000, 5000L * 1000 * 1000,
    10000L * 1000 * 1000, 20000L * 1000 * 1000, 50000L * 1000 * 1000,
};
static const size_t kVibeDropboxDownloadBudgetCount = sizeof(kVibeDropboxDownloadBudgets) / sizeof(kVibeDropboxDownloadBudgets[0]);
static const size_t kVibeDropboxDefaultDownloadBudgetIndex = 3;

// A saved budget's place among the choices: absent (0), the default's; off
// the list, the nearest's (VibeNearestPreset).
static inline size_t VibeDropboxDownloadBudgetIndex(NSInteger saved) {
    NSInteger budget = saved > 0 ? VibeNearestPreset(saved, kVibeDropboxDownloadBudgets, kVibeDropboxDownloadBudgetCount)
                                 : kVibeDropboxDownloadBudgets[kVibeDropboxDefaultDownloadBudgetIndex];
    size_t index = 0;
    while (kVibeDropboxDownloadBudgets[index] != budget) {
        index++;
    }
    return index;
}

NS_ASSUME_NONNULL_END

#endif
