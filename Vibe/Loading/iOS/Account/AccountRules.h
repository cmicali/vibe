//
//  AccountRules.h
//  Vibe (iOS)
//
//  The decisions every account source shares that need no network and no
//  disk: the PKCE pieces, the query and form encoding, the JSON body, the
//  revoked grant, the timestamps, the index key, which names are mirrored,
//  and the download budgets. Header-only and Foundation-only so the macOS suite tests
//  it. Each service's own rules are its own file (DropboxRules.h,
//  GoogleDriveRules.h).
//

#ifndef AccountRules_h
#define AccountRules_h

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

#import "PlaylistFile.h"
#import "SettingsRules.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - OAuth

// RFC 7636 appendix A: base64url, no padding.
static inline NSString *VibeAccountBase64URL(NSData *data) {
    NSString *base64 = [data base64EncodedStringWithOptions:0];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [base64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

// S256: base64url(SHA-256(ASCII verifier)).
static inline NSString *VibeAccountCodeChallenge(NSString *verifier) {
    NSData *ascii = [verifier dataUsingEncoding:NSASCIIStringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(ascii.bytes, (CC_LONG)ascii.length, digest);
    return VibeAccountBase64URL([NSData dataWithBytes:digest length:sizeof digest]);
}

// The code from the redirect, or nil with the reason. A state that does not
// match the one sent is refused: the redirect did not come from our request.
static inline NSString *_Nullable VibeAccountAuthorizationCode(NSURL *callback,
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

// The fields as a query string, keys sorted, each value percent-encoded
// ('+' and '&' included).
// TRAP: the unreserved set is ASCII alone. alphanumericCharacterSet holds
// every script's letters, and a search for "Beyoncé" would leave its "é"
// raw in percentEncodedQuery, which refuses it.
static inline NSString *VibeAccountQueryString(NSDictionary<NSString *, NSString *> *fields) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSMutableArray<NSString *> *pairs = [NSMutableArray arrayWithCapacity:fields.count];
    for (NSString *key in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *value = [fields[key] stringByAddingPercentEncodingWithAllowedCharacters:allowed];
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    return [pairs componentsJoinedByString:@"&"];
}

// application/x-www-form-urlencoded, as a token endpoint takes it.
static inline NSData *VibeAccountFormBody(NSDictionary<NSString *, NSString *> *fields) {
    return [VibeAccountQueryString(fields) dataUsingEncoding:NSUTF8StringEncoding];
}

// An answer's JSON object, nil for an empty body or anything but an object.
static inline NSDictionary *_Nullable VibeAccountJSONObject(NSData *_Nullable data) {
    if (data.length == 0) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

// The OAuth error a refresh gets once the grant is revoked (RFC 6749 5.2).
// Any other 400 (a captive portal, a proxy) must not unlink, which deletes
// every download.
static inline BOOL VibeAccountIsRevokedGrant(NSInteger status, NSDictionary *_Nullable body) {
    return status == 400 && [body[@"error"] isEqual:@"invalid_grant"];
}

// RFC 3339 in UTC to the second, with or without a fraction
// ("2015-05-12T15:50:38Z", "2024-01-02T03:04:05.678Z"); -1 for anything
// else. strptime, not a date formatter: called per entry, per thread.
static inline time_t VibeAccountParseTimestamp(NSString *_Nullable text) {
    if (![text isKindOfClass:NSString.class]) {
        return -1;
    }
    struct tm parts = {0};
    const char *end = strptime(text.UTF8String, "%Y-%m-%dT%H:%M:%S", &parts);
    if (!end) {
        return -1;
    }
    if (*end == '.') {
        end++;
        while (*end >= '0' && *end <= '9') {
            end++;
        }
    }
    if (end[0] != 'Z' || end[1] != '\0') {
        return -1;
    }
    return timegm(&parts);
}

#pragma mark - Names

// TRAP: a file URL's path comes back decomposed (NFD: "e" plus a combining
// accent) whatever was written, while a service keeps the name as uploaded,
// usually composed. A name read back from disk is never sent to a service;
// each directory's index holds what the service said, keyed by this form.
// Case folds too, so two names one volume would merge land apart on every
// volume.
static inline NSString *VibeAccountIndexKey(NSString *name) {
    return name.precomposedStringWithCanonicalMapping.lowercaseString;
}

// A directory's names by VibeAccountIndexKey, built once per listing.
static inline NSDictionary<NSString *, NSString *> *VibeAccountNameIndex(NSArray<NSString *> *names) {
    NSMutableDictionary<NSString *, NSString *> *index = [NSMutableDictionary dictionaryWithCapacity:names.count];
    for (NSString *name in names) {
        index[VibeAccountIndexKey(name)] = name;
    }
    return index;
}

// Which entries a mirror keeps: playable audio, and the playlist files the
// listing reads beside it. Everything else costs a placeholder for nothing.
static inline BOOL VibeAccountNameIsMirrored(NSString *name, NSSet<NSString *> *playableExtensions) {
    if ([name hasPrefix:@"."]) {
        return NO;
    }
    NSString *extension = name.pathExtension.lowercaseString;
    return [PlaylistFile isPlaylistExtension:extension] || [playableExtensions containsObject:extension];
}

#pragma mark - Downloads

// The sizes a mirror's downloads may reach before the oldest go back to
// placeholders, smallest first. The default is 10 GB.
static const NSInteger kVibeAccountDownloadBudgets[] = {
    1000L * 1000 * 1000, 2000L * 1000 * 1000, 5000L * 1000 * 1000,
    10000L * 1000 * 1000, 20000L * 1000 * 1000, 50000L * 1000 * 1000,
};
static const size_t kVibeAccountDownloadBudgetCount = sizeof(kVibeAccountDownloadBudgets) / sizeof(kVibeAccountDownloadBudgets[0]);
static const size_t kVibeAccountDefaultDownloadBudgetIndex = 3;

// A saved budget's place among the choices: absent (0), the default's; off
// the list, the nearest's (VibeNearestPreset).
static inline size_t VibeAccountDownloadBudgetIndex(NSInteger saved) {
    NSInteger budget = saved > 0 ? VibeNearestPreset(saved, kVibeAccountDownloadBudgets, kVibeAccountDownloadBudgetCount)
                                 : kVibeAccountDownloadBudgets[kVibeAccountDefaultDownloadBudgetIndex];
    size_t index = 0;
    while (kVibeAccountDownloadBudgets[index] != budget) {
        index++;
    }
    return index;
}

NS_ASSUME_NONNULL_END

#endif
