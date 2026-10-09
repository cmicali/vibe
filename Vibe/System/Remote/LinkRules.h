//
//  LinkRules.h
//  Vibe
//
//  The decisions behind Open URL that need no network and no disk: which
//  addresses Vibe fetches, whether the first bytes are audio, the file's name,
//  and how a link's directory and download are named and sized. Header-only
//  and Foundation-only so the host-less suite tests it.
//

#ifndef LinkRules_h
#define LinkRules_h

#import <Foundation/Foundation.h>

#import "NSURL+Hash.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>

NS_ASSUME_NONNULL_BEGIN

// The size the downloads of every link may reach before the oldest go back to
// placeholders. Decimal, as the Dropbox budgets are.
static const NSInteger kVibeLinkDownloadBudgetBytes = 2000L * 1000 * 1000;

#pragma mark - Acceptance

typedef NS_ENUM(NSInteger, VibeLinkAcceptance) {
    VibeLinkAccepted,
    // Not http or https: ftp, file, a custom scheme.
    VibeLinkRefusedNotHTTP,
    // Plain http to a host that is not on the local network.
    VibeLinkRefusedInsecurePublicHTTP,
    // No scheme, no host, or not a URL at all.
    VibeLinkRefusedInvalid,
};

static inline BOOL VibeLinkIPv4IsLocal(struct in_addr address) {
    uint32_t a = ntohl(address.s_addr);
    return (a >> 24) == 10                   // 10/8
        || (a >> 24) == 127                  // 127/8
        || (a >> 20) == ((172u << 4) | 1)    // 172.16/12
        || (a >> 16) == ((192u << 8) | 168)  // 192.168/16
        || (a >> 16) == ((169u << 8) | 254); // 169.254/16
}

static inline BOOL VibeLinkIPv6IsLocal(struct in6_addr address) {
    const uint8_t *b = address.s6_addr;
    if (IN6_IS_ADDR_LOOPBACK(&address)) return YES;   // ::1
    if ((b[0] & 0xFE) == 0xFC) return YES;           // fc00::/7
    if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return YES;  // fe80::/10
    if (IN6_IS_ADDR_V4MAPPED(&address)) {
        struct in_addr v4;
        memcpy(&v4.s_addr, b + 12, 4);
        return VibeLinkIPv4IsLocal(v4);
    }
    return NO;
}

// Whether a host is on the local network: localhost, a name ending in .local,
// .localhost or .test, an unqualified name, or an address in a private,
// loopback or link-local range. Takes NSURL.host as it comes, brackets and an
// IPv6 zone id included. It also picks the local-network error message.
//
// TRAP: an IPv4 address is parsed as the resolver parses it (inet_aton).
// "134744072" and "0x8.8.8.8" are 8.8.8.8, not unqualified names. Treating a
// bare number as a name would let plain http reach any public address.
static inline BOOL VibeLinkHostIsLocal(NSString *_Nullable host) {
    NSString *name = host.lowercaseString;
    if ([name hasPrefix:@"["] && [name hasSuffix:@"]"] && name.length >= 2) {
        name = [name substringWithRange:NSMakeRange(1, name.length - 2)];
    }
    NSRange zone = [name rangeOfString:@"%"];
    if (zone.location != NSNotFound) {
        name = [name substringToIndex:zone.location];
    }
    if ([name hasSuffix:@"."]) {
        name = [name substringToIndex:name.length - 1];
    }
    if (name.length == 0) return NO;

    const char *c = name.UTF8String;
    struct in6_addr v6;
    if (inet_pton(AF_INET6, c, &v6) == 1) return VibeLinkIPv6IsLocal(v6);
    struct in_addr v4;
    if (inet_aton(c, &v4) == 1) return VibeLinkIPv4IsLocal(v4);
    if ([name rangeOfString:@":"].location != NSNotFound) return NO;

    if ([name isEqualToString:@"localhost"]) return YES;
    for (NSString *suffix in @[@".local", @".localhost", @".test"]) {
        if ([name hasSuffix:suffix]) return YES;
    }
    return [name rangeOfString:@"."].location == NSNotFound;
}

// https reaches any host. Plain http reaches only the local network. App
// Transport Security's NSAllowsLocalNetworking draws the same line. The
// transfer applies this to every redirect too. A redirect can leave the local
// network.
static inline VibeLinkAcceptance VibeLinkURLAcceptance(NSURL *_Nullable url) {
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme.length == 0) return VibeLinkRefusedInvalid;
    BOOL https = [scheme isEqualToString:@"https"];
    if (!https && ![scheme isEqualToString:@"http"]) return VibeLinkRefusedNotHTTP;
    if (url.host.length == 0) return VibeLinkRefusedInvalid;
    if (https || VibeLinkHostIsLocal(url.host)) return VibeLinkAccepted;
    return VibeLinkRefusedInsecurePublicHTTP;
}

// The typed text as a URL: surrounding whitespace and newlines dropped, as a
// paste often carries them. nil when it does not parse.
static inline NSURL *_Nullable VibeLinkURLFromString(NSString *_Nullable text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 0 ? [NSURL URLWithString:trimmed] : nil;
}

#pragma mark - Dropbox share links

// A Dropbox share link to a file (/scl/fi/… or /s/…) with dl=1. That form
// answers a redirect to the bytes. Every other URL comes back unchanged. The
// other query items, rlkey among them, are kept. docs/future/share-links.md
// has the probe.
static inline NSURL *VibeLinkDirectDownloadURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!([host isEqualToString:@"dropbox.com"] || [host isEqualToString:@"www.dropbox.com"])) return url;
    NSString *path = url.path;
    if (!([path hasPrefix:@"/scl/fi/"] || [path hasPrefix:@"/s/"])) return url;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (components == nil) return url;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isEqualToString:@"dl"]) [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"dl" value:@"1"]];
    components.queryItems = items;
    return components.URL ?: url;
}

#pragma mark - Audio check

// The file type the first bytes name, with the extensions that share it. nil
// when no audio type matches. A head shorter than a signature matches nothing
// that needs it.
static inline NSString *_Nullable VibeLinkExtensionOfMagic(NSData *head,
                                                           NSSet<NSString *> *_Nullable *_Nullable family) {
    const uint8_t *b = head.bytes;
    NSUInteger n = head.length;
    NSString *extension = nil;
    NSArray<NSString *> *members = nil;

    if (n >= 3 && memcmp(b, "ID3", 3) == 0) {
        // ID3 is a tag, not a codec. It also leads ADTS and some FLAC files.
        extension = @"mp3";
        members = @[@"mp3", @"mp2", @"aac", @"adts", @"flac"];
    } else if (n >= 2 && b[0] == 0xFF && (b[1] & 0xF6) == 0xF0) {
        // ADTS: the MPEG sync with layer 00.
        extension = @"aac";
        members = @[@"aac", @"adts"];
    } else if (n >= 3 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0
               && ((b[1] >> 3) & 3) != 1          // version not reserved
               && ((b[1] >> 1) & 3) != 0          // a layer
               && (b[2] >> 4) != 0xF              // bitrate not bad
               && ((b[2] >> 2) & 3) != 3) {       // sample rate not reserved
        extension = ((b[1] >> 1) & 3) == 2 ? @"mp2" : @"mp3";
        members = @[@"mp3", @"mp2"];
    } else if (n >= 4 && memcmp(b, "fLaC", 4) == 0) {
        extension = @"flac";
        members = @[@"flac"];
    } else if (n >= 12 && memcmp(b, "RIFF", 4) == 0 && memcmp(b + 8, "WAVE", 4) == 0) {
        extension = @"wav";
        members = @[@"wav", @"wave", @"bwf"];
    } else if (n >= 16 && memcmp(b, "riff\x2E\x91\xCF\x11\xA5\xD6\x28\xDB\x04\xC1\x00\x00", 16) == 0) {
        extension = @"w64";
        members = @[@"w64"];
    } else if (n >= 12 && memcmp(b, "FORM", 4) == 0
               && (memcmp(b + 8, "AIFF", 4) == 0 || memcmp(b + 8, "AIFC", 4) == 0)) {
        extension = @"aiff";
        members = @[@"aiff", @"aif"];
    } else if (n >= 4 && memcmp(b, "OggS", 4) == 0) {
        // Opus and Vorbis share the container. The head is too short to tell
        // them apart. The link's own extension decides.
        extension = @"ogg";
        members = @[@"ogg", @"oga", @"opus"];
    } else if (n >= 8 && memcmp(b + 4, "ftyp", 4) == 0) {
        extension = @"m4a";
        members = @[@"m4a", @"mp4", @"m4b", @"m4r", @"qta"];
    } else if (n >= 4 && memcmp(b, "caff", 4) == 0) {
        extension = @"caf";
        members = @[@"caf"];
    }
    if (family != NULL) *family = members != nil ? [NSSet setWithArray:members] : nil;
    return extension;
}

// The extension a media type names, parameters ignored. nil for anything not
// audio, application/octet-stream included.
static inline NSString *_Nullable VibeLinkExtensionOfContentType(NSString *_Nullable contentType) {
    NSString *type = [[contentType componentsSeparatedByString:@";"].firstObject
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    if (type.length == 0) return nil;
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"audio/mpeg": @"mp3", @"audio/mp3": @"mp3",
            @"audio/mp4": @"m4a", @"audio/x-m4a": @"m4a",
            @"audio/aac": @"aac", @"audio/aacp": @"aac", @"audio/x-aac": @"aac",
            @"audio/flac": @"flac", @"audio/x-flac": @"flac",
            @"audio/wav": @"wav", @"audio/x-wav": @"wav", @"audio/wave": @"wav", @"audio/vnd.wave": @"wav",
            @"audio/aiff": @"aiff", @"audio/x-aiff": @"aiff",
            @"audio/ogg": @"ogg", @"audio/opus": @"opus",
        };
    });
    return map[type];
}

// The file name a Content-Disposition header gives. The RFC 5987 filename*
// form wins over the plain one. nil when there is none.
static inline NSString *_Nullable VibeLinkFilenameOfContentDisposition(NSString *_Nullable header) {
    NSString *plain = nil;
    NSString *extended = nil;
    for (NSString *part in [header componentsSeparatedByString:@";"]) {
        NSRange equals = [part rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [[part substringToIndex:equals.location]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
        NSString *value = [[part substringFromIndex:NSMaxRange(equals)]
                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([key isEqualToString:@"filename*"]) {
            // charset'language'percent-encoded
            NSArray<NSString *> *pieces = [value componentsSeparatedByString:@"'"];
            if (pieces.count == 3) extended = pieces[2].stringByRemovingPercentEncoding;
        } else if ([key isEqualToString:@"filename"]) {
            if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
                value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
            }
            plain = value;
        }
    }
    NSString *name = extended.length > 0 ? extended : plain;
    return name.length > 0 ? name : nil;
}

// The extension a link's file gets, or nil when it is not audio. In order: the
// first bytes; the URL path's extension; the Content-Disposition file name's;
// the Content-Type. When the bytes name a family (Ogg, MP4, WAV), the URL's or
// the file name's extension picks the member. HTML the bytes do not claim is
// not audio, whatever its URL says. Pass the link's URL, not the redirect's.
// A CDN's path carries no name. playable is PlayableExtensions.lookup.
static inline NSString *_Nullable VibeLinkAudioExtension(NSData *head,
                                                         NSURL *url,
                                                         NSString *_Nullable contentDisposition,
                                                         NSString *_Nullable contentType,
                                                         NSSet<NSString *> *playable) {
    NSString *urlExtension = url.path.pathExtension.lowercaseString;
    NSString *dispositionExtension = VibeLinkFilenameOfContentDisposition(contentDisposition).pathExtension.lowercaseString;

    NSSet<NSString *> *family = nil;
    NSString *magic = VibeLinkExtensionOfMagic(head, &family);
    if (magic != nil) {
        if (urlExtension.length > 0 && [family containsObject:urlExtension]) return urlExtension;
        if (dispositionExtension.length > 0 && [family containsObject:dispositionExtension]) return dispositionExtension;
        return magic;
    }
    NSString *type = [[contentType componentsSeparatedByString:@";"].firstObject
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    if ([type isEqualToString:@"text/html"]) return nil;
    if (urlExtension.length > 0 && [playable containsObject:urlExtension]) return urlExtension;
    if (dispositionExtension.length > 0 && [playable containsObject:dispositionExtension]) return dispositionExtension;
    NSString *typed = VibeLinkExtensionOfContentType(contentType);
    return typed != nil && [playable containsObject:typed] ? typed : nil;
}

#pragma mark - Naming

static const NSUInteger kVibeLinkNameMaxBytes = 200;

// The link's file name: the URL's last path component, percent-decoded and
// cleaned, with extension forced on. A playable extension it already carries
// is replaced. Cleaning swaps '/' and ':' for '-' and drops C0 and C1 control
// characters and leading dots. The whole name is cut to 200 UTF-8 bytes on a
// character boundary. "Link.<extension>" when nothing survives.
static inline NSString *VibeLinkFileName(NSURL *url, NSString *extension, NSSet<NSString *> *playable) {
    // The encoded path, split before decoding: a %2F belongs to the name.
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *name = @"";
    for (NSString *component in [components.percentEncodedPath componentsSeparatedByString:@"/"]) {
        if (component.length > 0) name = component;
    }
    name = name.stringByRemovingPercentEncoding ?: name;
    // Cc only. NSCharacterSet.controlCharacterSet also holds Cf, and that
    // takes the joiner out of an emoji sequence or a Persian word.
    NSMutableCharacterSet *controls = [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0x00, 0x20)];
    [controls addCharactersInRange:NSMakeRange(0x7F, 0x21)];
    name = [[name componentsSeparatedByCharactersInSet:controls] componentsJoinedByString:@""];
    name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    name = [name stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    if ([playable containsObject:name.pathExtension.lowercaseString]) {
        name = name.stringByDeletingPathExtension;
    }
    NSCharacterSet *edges = NSCharacterSet.whitespaceCharacterSet;
    name = [name stringByTrimmingCharactersInSet:edges];
    while ([name hasPrefix:@"."]) {
        name = [[name substringFromIndex:1] stringByTrimmingCharactersInSet:edges];
    }

    NSString *suffix = [@"." stringByAppendingString:extension];
    NSUInteger budget = kVibeLinkNameMaxBytes - [suffix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if ([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > budget) {
        __block NSUInteger end = 0;
        __block NSUInteger bytes = 0;
        [name enumerateSubstringsInRange:NSMakeRange(0, name.length)
                                 options:NSStringEnumerationByComposedCharacterSequences
                              usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
            NSUInteger size = [character lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (bytes + size > budget) {
                *stop = YES;
                return;
            }
            bytes += size;
            end = NSMaxRange(range);
        }];
        name = [[name substringToIndex:end] stringByTrimmingCharactersInSet:edges];
    }
    if (name.length == 0) name = @"Link";
    return [name stringByAppendingString:suffix];
}

// The URL a link is known by: the scheme and host lowercased, the fragment
// dropped. The same link typed twice is one record.
static inline NSString *VibeLinkNormalizedURLString(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (components == nil) return url.absoluteString;
    components.scheme = components.scheme.lowercaseString;
    components.percentEncodedHost = components.percentEncodedHost.lowercaseString;
    components.fragment = nil;
    return components.string ?: url.absoluteString;
}

// The link's directory under Links/: the first 16 hex digits of the SHA-1 of
// its normalized URL.
static inline NSString *VibeLinkDirectoryName(NSURL *url) {
    NSString *hex = [[VibeLinkNormalizedURLString(url) dataUsingEncoding:NSUTF8StringEncoding] sha1Hex];
    return [hex substringToIndex:16];
}

#pragma mark - Response headers

// The total of a Content-Range header. "bytes 0-15/12345" and "bytes */12345"
// are both 12345. -1 when the total is unknown ("*") or the header does not
// parse.
static inline long long VibeLinkContentRangeTotal(NSString *_Nullable header) {
    NSString *value = [header stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (![value.lowercaseString hasPrefix:@"bytes"]) return -1;
    NSRange slash = [value rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) return -1;
    NSString *total = [[value substringFromIndex:NSMaxRange(slash)]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    // 18 digits fit a long long. A longer total would scan as LLONG_MAX.
    if (total.length == 0 || total.length > 18
        || [total rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) {
        return -1;
    }
    NSScanner *scanner = [NSScanner scannerWithString:total];
    long long size = -1;
    return [scanner scanLongLong:&size] && scanner.isAtEnd && size >= 0 ? size : -1;
}

// An ETag that names exact bytes. A weak one (W/"…") says only that two
// responses mean the same. It counts as absent. A strong one is kept as sent,
// quotes included. It is compared as an opaque string.
static inline NSString *_Nullable VibeLinkStrongETag(NSString *_Nullable etag) {
    NSString *value = [etag stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (value.length == 0 || [value hasPrefix:@"W/"] || [value hasPrefix:@"w/"]) return nil;
    return value;
}

#pragma mark - Failures

// Why a link did not open. Each shell turns one into its link.error string.
// The names follow the string keys.
typedef NS_ENUM(NSInteger, VibeLinkError) {
    VibeLinkErrorNone,
    VibeLinkErrorInvalid,
    VibeLinkErrorInsecure,
    VibeLinkErrorUnreachable,
    VibeLinkErrorLocalNetwork,
    VibeLinkErrorNotFound,
    VibeLinkErrorDenied,
    VibeLinkErrorNotAudio,
    VibeLinkErrorNoSize,
    VibeLinkErrorLiveStream,
    VibeLinkErrorServer,
};

// A refused address. Another scheme is as invalid as no address at all.
static inline VibeLinkError VibeLinkErrorOfAcceptance(VibeLinkAcceptance acceptance) {
    switch (acceptance) {
        case VibeLinkAccepted: return VibeLinkErrorNone;
        case VibeLinkRefusedInsecurePublicHTTP: return VibeLinkErrorInsecure;
        case VibeLinkRefusedNotHTTP:
        case VibeLinkRefusedInvalid: return VibeLinkErrorInvalid;
    }
    return VibeLinkErrorInvalid;
}

// An HTTP status. A 2xx is no failure. A redirect the session did not follow
// is the server's failure, like every other status not named here.
static inline VibeLinkError VibeLinkErrorOfStatus(NSInteger status) {
    if (status >= 200 && status < 300) return VibeLinkErrorNone;
    if (status == 401 || status == 403) return VibeLinkErrorDenied;
    if (status == 404 || status == 410) return VibeLinkErrorNotFound;
    return VibeLinkErrorServer;
}

// A request that got no response. App Transport Security's refusal is the
// insecure failure. A cancel is the caller's own and shows nothing. Any other
// failure to reach a local host is the local-network one. A denied
// local-network permission fails that way.
static inline VibeLinkError VibeLinkErrorOfNetworkError(NSError *_Nullable error, NSString *_Nullable host) {
    if (error == nil) return VibeLinkErrorNone;
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorCancelled: return VibeLinkErrorNone;
            case NSURLErrorAppTransportSecurityRequiresSecureConnection: return VibeLinkErrorInsecure;
            case NSURLErrorBadURL:
            case NSURLErrorUnsupportedURL: return VibeLinkErrorInvalid;
            default: break;
        }
    }
    return VibeLinkHostIsLocal(host) ? VibeLinkErrorLocalNetwork : VibeLinkErrorUnreachable;
}

// A response with no size. Icecast and SHOUTcast send icy- headers. An audio
// type sent chunked is a stream too. Neither can be placed on disk. Header
// names match in any case, as NSHTTPURLResponse gives them.
static inline VibeLinkError VibeLinkErrorOfMissingSize(NSDictionary *_Nullable headers) {
    BOOL chunked = NO;
    NSString *contentType = nil;
    for (id key in headers) {
        if (![key isKindOfClass:NSString.class]) continue;
        NSString *name = [(NSString *)key lowercaseString];
        id value = headers[key];
        NSString *text = [value isKindOfClass:NSString.class] ? value : nil;
        if ([name hasPrefix:@"icy-"]) return VibeLinkErrorLiveStream;
        if ([name isEqualToString:@"transfer-encoding"]) {
            chunked = [text.lowercaseString rangeOfString:@"chunked"].location != NSNotFound;
        } else if ([name isEqualToString:@"content-type"]) {
            contentType = text;
        }
    }
    return chunked && VibeLinkExtensionOfContentType(contentType) != nil ? VibeLinkErrorLiveStream
                                                                        : VibeLinkErrorNoSize;
}

NS_ASSUME_NONNULL_END

#endif /* LinkRules_h */
