//
//  ICloudLinkRules.h
//  Vibe
//
//  Open URL's iCloud Drive share links. LinkStore's LinkClient asks this file
//  before each request to one. No other link code knows iCloud. Header-only
//  and Foundation-only, so the macOS suite tests it.
//
//  What iCloud answers a link, measured on a shared 526 MB FLAC. The share
//  page is a script, not the file, so nothing rewrites the link. A POST to
//  CloudKit's records/resolve looks the share up with no sign-in. Its answer
//  states the file's checksum, size, mtime, and name, and a signed download
//  address on cvws.icloud-content.com. The name is only base64: a public
//  share is not encrypted. The answer also names the owner. Nothing reads
//  that. The address expires about 15 minutes on, and past that answers 410
//  Gone. A range there gets a 206 with Content-Range, and the bytes are the
//  file's own. It sends no ETag. Its Last-Modified is when it signed the
//  address. So the version is the lookup's checksum, and the mtime is the
//  lookup's. iCloud sends the name in the address back as the file's
//  Content-Disposition.
//

#ifndef ICloudLinkRules_h
#define ICloudLinkRules_h

#import <Foundation/Foundation.h>

#import "LinkRules.h"

NS_ASSUME_NONNULL_BEGIN

// Each request first looks the share up at this address.
static NSString *const kVibeICloudLinkLookupURL =
    @"https://ckdatabasews.icloud.com/database/1/com.apple.cloudkit/production/public/records/resolve";

// A looked-up address is sent for this long. iCloud signs one for about 15
// minutes. Its own expiry is in iCloud's clock, so it is never compared with
// this device's: a clock 15 minutes fast would find every address expired.
static const NSTimeInterval kVibeICloudLinkAddressLifetime = 10 * 60;

// The share id of an iCloud Drive file link: https://www.icloud.com/
// iclouddrive/<id>, or icloud.com. The fragment holds a display name and is
// ignored, as is a query. Nil for every other URL, and for an id with
// characters an id never has.
static inline NSString *_Nullable VibeICloudLinkShortGUID(NSURL *_Nullable url) {
    NSString *host = url.host.lowercaseString;
    if (!([host isEqualToString:@"www.icloud.com"] || [host isEqualToString:@"icloud.com"])) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [components.percentEncodedPath componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part];
    }
    if (parts.count != 2 || ![parts[0] isEqualToString:@"iclouddrive"]) return nil;
    NSCharacterSet *idCharacters =
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    NSString *shortGUID = parts[1];
    return [shortGUID rangeOfCharacterFromSet:idCharacters.invertedSet].location == NSNotFound ? shortGUID : nil;
}

// The lookup's body for one share. Sent as text/plain from the icloud.com
// origin, as iCloud's own page sends it.
static inline NSData *VibeICloudLinkLookupBody(NSString *shortGUID) {
    return [NSJSONSerialization dataWithJSONObject:@{@"shortGUIDs": @[@{@"value": shortGUID}]} options:0 error:NULL];
}

// A file name with every character but the unreserved ones percent-encoded.
static inline NSString *VibeICloudLinkEncodedName(NSString *name) {
    NSCharacterSet *unreserved =
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    return [name stringByAddingPercentEncodingWithAllowedCharacters:unreserved] ?: @"";
}

// The download address for the file's name: ${f} in the lookup's address,
// replaced by the name, percent-encoded, as iCloud's own page does. Nil
// unless the result is an https address with a host.
static inline NSURL *_Nullable VibeICloudLinkDownloadURL(NSString *_Nullable address, NSString *name) {
    NSString *encoded = VibeICloudLinkEncodedName(name);
    if (address.length == 0 || encoded.length == 0) return nil;
    NSURL *url = [NSURL URLWithString:[address stringByReplacingOccurrencesOfString:@"${f}" withString:encoded]];
    return [url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length > 0 ? url : nil;
}

// The Content-Disposition that names the link's file (VibeLinkFileName) by
// the lookup's name. iCloud echoes the name in ${f} the same way, but the
// lookup is what states it.
static inline NSString *VibeICloudLinkContentDisposition(NSString *name) {
    return [NSString stringWithFormat:@"attachment; filename*=UTF-8''%@", VibeICloudLinkEncodedName(name)];
}

// Whether a looked-up address may still be sent: looked up under 10 minutes
// ago. Both times are the system's uptime, which no clock change moves. An
// address that expires sooner is refused, and looked up again
// (VibeICloudLinkStatusIsStaleAddress).
static inline BOOL VibeICloudLinkAddressIsFresh(NSTimeInterval lookedUp, NSTimeInterval now) {
    return now >= lookedUp && now - lookedUp < kVibeICloudLinkAddressLifetime;
}

// Whether a download address's refusal may mean only that it expired, which
// a fresh lookup cures. An expired address answers 410, and a bad signature
// 400.
static inline BOOL VibeICloudLinkStatusIsStaleAddress(NSInteger status) {
    return status == 400 || status == 401 || status == 403 || status == 410;
}

// One field of a CloudKit record, which wraps each as {value, type}. Nil
// unless its value is of `kind`.
static inline id _Nullable VibeICloudLinkField(id _Nullable fields, NSString *name, Class kind) {
    id field = [fields isKindOfClass:NSDictionary.class] ? ((NSDictionary *)fields)[name] : nil;
    id value = [field isKindOfClass:NSDictionary.class] ? ((NSDictionary *)field)[@"value"] : nil;
    return [value isKindOfClass:kind] ? value : nil;
}

// A number a lookup states, as a number or as a string of digits. -1 for
// none.
static inline long long VibeICloudLinkNumber(id _Nullable value) {
    if ([value isKindOfClass:NSNumber.class]) return [value longLongValue];
    return [value isKindOfClass:NSString.class] ? VibeHTTPParseLength(value) : -1;
}

// The file a lookup's answer describes, or why it opens nothing. On None,
// `file` is {checksum, size, modified, name, url}: the version, the size,
// the mtime in Unix seconds (left out when none is stated), the name with
// its extension, and the download address for that name.
// A share that needs a sign-in is Private, and so is one with no anonymous
// access. A share that is not one file is Folder. One that no longer exists
// is NotFound. Any other answer is Unreadable, never a server error.
// The answer also names the owner. Nothing here reads that.
static inline VibeLinkError VibeICloudLinkFileOfLookup(id _Nullable answer,
                                                       NSDictionary *_Nullable *_Nullable file) {
    if (file != NULL) *file = nil;
    NSArray *results = [answer isKindOfClass:NSDictionary.class] ? ((NSDictionary *)answer)[@"results"] : nil;
    NSDictionary *result = [results isKindOfClass:NSArray.class] && results.count > 0 ? results.firstObject : nil;
    if (![result isKindOfClass:NSDictionary.class]) return VibeLinkErrorICloudUnreadable;
    if ([result[@"requireAppleLogin"] isKindOfClass:NSNumber.class] && [result[@"requireAppleLogin"] boolValue]) {
        return VibeLinkErrorICloudPrivate;
    }
    id code = result[@"serverErrorCode"];
    if (code) {
        if ([code isEqual:@"NOT_FOUND"]) return VibeLinkErrorNotFound;
        BOOL authentication = [code isKindOfClass:NSString.class] && [code hasPrefix:@"AUTHENTICATION_"];
        if ([code isEqual:@"ACCESS_DENIED"] || authentication) return VibeLinkErrorICloudPrivate;
        return VibeLinkErrorICloudUnreadable;
    }
    // Every answer names its share. One with no anonymous access to it is
    // shared only with invited people.
    if (!result[@"shortGUID"]) return VibeLinkErrorICloudUnreadable;
    if (![result[@"anonymousPublicAccess"] isKindOfClass:NSDictionary.class]) return VibeLinkErrorICloudPrivate;
    NSDictionary *record = result[@"rootRecord"];
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"recordType"] isKindOfClass:NSString.class]) {
        return VibeLinkErrorICloudUnreadable;
    }
    if (![record[@"recordType"] isEqualToString:@"content"]) return VibeLinkErrorICloudFolder;

    NSDictionary *fields = record[@"fields"];
    NSDictionary *content = VibeICloudLinkField(fields, @"fileContent", NSDictionary.class);
    NSString *checksum = [content[@"fileChecksum"] isKindOfClass:NSString.class] ? content[@"fileChecksum"] : nil;
    NSString *address = [content[@"downloadURL"] isKindOfClass:NSString.class] ? content[@"downloadURL"] : nil;
    long long size = VibeICloudLinkNumber(VibeICloudLinkField(fields, @"size", NSObject.class));
    if (size < 0) size = VibeICloudLinkNumber(content[@"size"]);
    long long modified = VibeICloudLinkNumber(VibeICloudLinkField(fields, @"mtime", NSObject.class));
    // Only base64 of the name. A public share is not encrypted.
    NSString *encoded = VibeICloudLinkField(fields, @"encryptedBasename", NSString.class);
    NSData *basename = encoded ? [[NSData alloc] initWithBase64EncodedString:encoded options:0] : nil;
    NSString *name = basename ? [[NSString alloc] initWithData:basename encoding:NSUTF8StringEncoding] : nil;
    NSString *extension = VibeICloudLinkField(fields, @"extension", NSString.class);
    if (name.length == 0) name = @"Link";
    if (extension.length > 0) name = [name stringByAppendingFormat:@".%@", extension];
    NSURL *url = VibeICloudLinkDownloadURL(address, name);
    if (checksum.length == 0 || size < 0 || !url) {
        return VibeLinkErrorICloudUnreadable;
    }
    if (file != NULL) {
        NSMutableDictionary *found = [@{@"checksum": checksum, @"size": @(size), @"name": name, @"url": url}
                                      mutableCopy];
        found[@"modified"] = modified >= 0 ? @(modified) : nil;
        *file = found;
    }
    return VibeLinkErrorNone;
}

NS_ASSUME_NONNULL_END

#endif /* ICloudLinkRules_h */
