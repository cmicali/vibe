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

#import "HTTPTransferRules.h"
#import "NSURL+Hash.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>

NS_ASSUME_NONNULL_BEGIN

// The size the downloads of every link may reach before the oldest go back to
// placeholders. Decimal, as the Dropbox budgets are.
static const NSInteger kVibeLinkDownloadBudgetBytes = 2000L * 1000 * 1000;

// Why a link did not open. Each shell turns one into its link.error string.
// The names follow the string keys. Cancelled has none: the user's own
// cancel shows nothing.
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
    VibeLinkErrorCancelled,
};

#pragma mark - Acceptance

// TRAP: 0.0.0.0/8 and :: are the unspecified addresses, and a connection to
// one reaches this machine. Left public, a public page could redirect Vibe to
// a service on the Mac itself.
static inline BOOL VibeLinkIPv4IsLocal(struct in_addr address) {
    uint32_t a = ntohl(address.s_addr);
    return (a >> 24) == 0                    // 0/8
        || (a >> 24) == 10                   // 10/8
        || (a >> 24) == 127                  // 127/8
        || (a >> 20) == ((172u << 4) | 1)    // 172.16/12
        || (a >> 16) == ((192u << 8) | 168)  // 192.168/16
        || (a >> 16) == ((169u << 8) | 254); // 169.254/16
}

static inline BOOL VibeLinkIPv6IsLocal(struct in6_addr address) {
    const uint8_t *b = address.s6_addr;
    if (IN6_IS_ADDR_UNSPECIFIED(&address)) return YES;  // ::
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
// .localhost, or .test, an unqualified name, or an address in a private,
// loopback, link-local, or unspecified range. Takes NSURL.host as it comes, with or without
// an IPv6 literal's brackets. It also picks the local-network error message.
//
// TRAP: an IPv4 address is parsed as the resolver parses it (inet_aton).
// "134744072" and "0x8.8.8.8" are 8.8.8.8, not unqualified names. Treating a
// bare number as a name would let plain http reach any public address.
//
// TRAP: a zone id ("%en0") belongs only to an IPv6 literal. A '%' anywhere
// else, or a NUL, makes the host not local. Cut there like a zone id,
// "pi%.example.com" would pass as the unqualified name "pi".
static inline BOOL VibeLinkHostIsLocal(NSString *_Nullable host) {
    NSString *name = host.lowercaseString;
    if ([name hasPrefix:@"["] && [name hasSuffix:@"]"] && name.length >= 2) {
        name = [name substringWithRange:NSMakeRange(1, name.length - 2)];
    }
    if ([name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location
            != NSNotFound) return NO;
    NSRange zone = [name rangeOfString:@"%"];
    if (zone.location != NSNotFound) {
        name = [name substringToIndex:zone.location];
        struct in6_addr literal;
        if (inet_pton(AF_INET6, name.UTF8String, &literal) != 1) return NO;
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

// The address rule: None for an address Vibe fetches. https reaches any
// host. Plain http reaches only the local network, and is Insecure past it.
// Another scheme, or no host, is Invalid. App Transport Security's
// NSAllowsLocalNetworking draws the same line. The transfer applies this to
// every redirect too (VibeLinkRequestIsAllowed). A redirect can leave the
// local network.
static inline VibeLinkError VibeLinkURLAcceptance(NSURL *_Nullable url) {
    NSString *scheme = url.scheme.lowercaseString;
    BOOL https = [scheme isEqualToString:@"https"];
    if (!https && ![scheme isEqualToString:@"http"]) return VibeLinkErrorInvalid;
    if (url.host.length == 0) return VibeLinkErrorInvalid;
    if (https || VibeLinkHostIsLocal(url.host)) return VibeLinkErrorNone;
    return VibeLinkErrorInsecure;
}

// Whether the transfer may request `to`, reached by a redirect from `from`,
// nil for the link itself. `to` must pass the address rule. A redirect from a
// public host never reaches the local network, whatever the scheme. A public
// page could otherwise send Vibe's requests to a device at home.
static inline BOOL VibeLinkRequestIsAllowed(NSURL *_Nullable from, NSURL *_Nullable to) {
    if (VibeLinkURLAcceptance(to) != VibeLinkErrorNone) return NO;
    return from == nil || VibeLinkHostIsLocal(from.host) || !VibeLinkHostIsLocal(to.host);
}

// The typed text as a URL: surrounding whitespace and newlines dropped, as a
// paste often carries them. nil when it does not parse.
static inline NSURL *_Nullable VibeLinkURLFromString(NSString *_Nullable text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 0 ? [NSURL URLWithString:trimmed] : nil;
}

// Whether the prompt's Open does nothing: the text is empty, or only spaces
// and newlines. Nothing typed is the same as Cancel. It is no address to
// refuse.
static inline BOOL VibeLinkTextIsBlank(NSString *_Nullable text) {
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0;
}

#pragma mark - Share links

// A Google Drive link to a file as Google's download address. The file's id
// comes from /file/d/<id>/…, or from the id item of /open or /uc. A folder
// link, or an id with characters an id never has, is not a file link. It
// answers nil. confirm=t skips the virus-scan page a large file gets. A
// resourcekey item is kept. Older shares need it.
static inline NSURL *_Nullable VibeLinkGoogleDriveDownloadURL(NSURL *url) {
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

// A share link to a file as the address that answers its bytes. A Dropbox
// link (/scl/fi/… or /s/…) gets dl=1, which answers a redirect to the bytes.
// Its other query items, rlkey among them, are kept. A Google Drive file link
// becomes Google's download address (above). Every other URL comes back
// unchanged. docs/future/share-links.md has the probes.
static inline NSURL *VibeLinkDirectDownloadURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"drive.google.com"]) return VibeLinkGoogleDriveDownloadURL(url) ?: url;
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

// The URL's last path component, percent-decoded. Empty when the path names
// nothing.
static inline NSString *VibeLinkLastPathName(NSURL *_Nullable url) {
    // The encoded path, split before decoding: a %2F belongs to the name.
    NSURLComponents *components = url ? [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO] : nil;
    NSString *name = @"";
    for (NSString *component in [components.percentEncodedPath componentsSeparatedByString:@"/"]) {
        if (component.length > 0) name = component;
    }
    return name.stringByRemovingPercentEncoding ?: name;
}

// What the mac's header calls a link that failed: its last path component,
// else its host, else the text as typed, trimmed.
static inline NSString *VibeLinkNameOfText(NSString *text) {
    NSURL *url = VibeLinkURLFromString(text);
    NSString *name = VibeLinkLastPathName(url);
    if (name.length == 0) name = url.host ?: @"";
    if (name.length == 0) name = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name;
}

// The link's file name, cleaned, with extension forced on. It is the URL's
// last path component, percent-decoded, when that carries a playable
// extension. Otherwise the Content-Disposition file name wins when there is
// one. Google Drive's path ends in "view" or "download" and names nothing.
// A playable extension the name already carries is replaced. Cleaning swaps
// '/' and ':' for '-' and drops C0 and C1 control characters, the bidi
// embeddings, overrides, and isolates, and leading dots. An override would
// show "mp3.exe" as "exe.3pm". The whole name is cut to 200 UTF-8 bytes on a character boundary.
// "Link.<extension>" when nothing survives.
static inline NSString *VibeLinkFileName(NSURL *url,
                                         NSString *_Nullable contentDisposition,
                                         NSString *extension,
                                         NSSet<NSString *> *playable) {
    NSString *name = VibeLinkLastPathName(url);
    NSString *disposition = VibeLinkFilenameOfContentDisposition(contentDisposition);
    if (disposition != nil && ![playable containsObject:name.pathExtension.lowercaseString]) {
        name = disposition;
    }
    // Cc and the bidi controls only. NSCharacterSet.controlCharacterSet also
    // holds the rest of Cf, and that takes the joiner out of an emoji
    // sequence or a Persian word.
    NSMutableCharacterSet *controls = [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0x00, 0x20)];
    [controls addCharactersInRange:NSMakeRange(0x7F, 0x21)];
    [controls addCharactersInRange:NSMakeRange(0x202A, 5)];  // LRE, RLE, PDF, LRO, RLO
    [controls addCharactersInRange:NSMakeRange(0x2066, 4)];  // LRI, RLI, FSI, PDI
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

#pragma mark - Drops

// The pasteboard types a drop on the mac's window is read for. Finder writes
// a file URL. A browser's link or address-bar drag writes a URL, and often
// the same link as text. Text from anywhere else may hold one link.
static NSString *const kVibeDropTypeFileURL = @"public.file-url";
static NSString *const kVibeDropTypeURL = @"public.url";
static NSString *const kVibeDropTypeText = @"public.utf8-plain-text";

// A .webloc is a small property list. Only this many bytes are read.
static const NSUInteger kVibeLinkWeblocMaxBytes = 64 * 1024;

// An http or https URL with a host. The address rule still decides whether
// Vibe fetches it. Plain http to a public host is a link that fails as
// insecure, before any request.
static inline BOOL VibeLinkIsWebLink(NSURL *_Nullable url) {
    return VibeLinkURLAcceptance(url) != VibeLinkErrorInvalid;
}

static inline BOOL VibeLinkIsWebloc(NSURL *url) {
    return url.isFileURL && [url.pathExtension.lowercaseString isEqualToString:@"webloc"];
}

// What a drop holds, in drop order. Each item is one pasteboard item's
// strings by type. A file URL wins, then a URL, then text. A file is kept as
// it came, since the shell pins its path. A URL or text that is no web link
// adds nothing. So does text holding anything but one link.
static inline NSArray<NSURL *> *VibeDropURLsOfItems(NSArray<NSDictionary<NSString *, NSString *> *> *items) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *item in items) {
        NSString *file = item[kVibeDropTypeFileURL];
        if (file) {
            NSURL *url = [NSURL URLWithString:file];
            if (url.isFileURL) [urls addObject:url];
            continue;
        }
        NSURL *link = VibeLinkURLFromString(item[kVibeDropTypeURL] ?: item[kVibeDropTypeText]);
        if (VibeLinkIsWebLink(link)) [urls addObject:link];
    }
    return urls;
}

// Whether a drop takes the link road: it holds a web link or a .webloc.
static inline BOOL VibeDropHasLinks(NSArray<NSURL *> *urls) {
    for (NSURL *url in urls) {
        if (!url.isFileURL || VibeLinkIsWebloc(url)) return YES;
    }
    return NO;
}

// A .webloc's link: the URL key of its property list, XML or binary. Nil
// when it holds no web link.
static inline NSURL *_Nullable VibeLinkURLOfWebloc(NSData *_Nullable data) {
    if (data.length == 0) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                          format:NULL error:NULL];
    id string = [plist isKindOfClass:NSDictionary.class] ? ((NSDictionary *)plist)[@"URL"] : nil;
    NSURL *url = [string isKindOfClass:NSString.class] ? VibeLinkURLFromString(string) : nil;
    return VibeLinkIsWebLink(url) ? url : nil;
}

// What a drop on the link road opens, in drop order: its files, and its
// links. Each .webloc is swapped for its link. read answers its first bytes,
// or nil. A .webloc with no web link opens nothing. A link the drop already
// holds is not added again, by the store's normalized URL.
static inline NSArray<NSURL *> *VibeDropOpenOrder(NSArray<NSURL *> *urls,
                                                  NSData *_Nullable (^read)(NSURL *webloc)) {
    NSMutableArray<NSURL *> *order = [NSMutableArray array];
    NSMutableSet<NSString *> *links = [NSMutableSet set];
    for (NSURL *dropped in urls) {
        NSURL *url = VibeLinkIsWebloc(dropped) ? VibeLinkURLOfWebloc(read(dropped)) : dropped;
        if (url == nil) continue;
        if (!url.isFileURL) {
            NSString *key = VibeLinkNormalizedURLString(url);
            if ([links containsObject:key]) continue;
            [links addObject:key];
        }
        [order addObject:url];
    }
    return order;
}

#pragma mark - Pruning

// A link not opened for this long is deleted at launch, unless something
// still names it.
static const NSTimeInterval kVibeLinkPruneAgeSeconds = 30 * 24 * 60 * 60;

// The URLs that keep their links from the launch's pruning: the playlist's
// rows as the launch restored them, and the recent items. Each shell passes
// its own lists. Only file URLs count.
static inline NSSet<NSURL *> *VibeLinkKeptURLs(NSArray<NSURL *> *rows, NSArray<NSURL *> *recents) {
    NSMutableSet<NSURL *> *kept = [NSMutableSet set];
    for (NSArray<NSURL *> *list in @[rows, recents]) {
        for (NSURL *url in list) {
            if (url.isFileURL) {
                [kept addObject:url];
            }
        }
    }
    return kept;
}

// The link directories to delete, by name, sorted. records maps each
// directory's name to its record, NSNull for a directory with none. One
// opened more than 30 days before now goes, unless kept names it. A record
// with no opened time counts as opened long ago.
static inline NSArray<NSString *> *VibeLinkDirectoriesToPrune(NSDictionary<NSString *, id> *records,
                                                             NSSet<NSString *> *kept,
                                                             NSTimeInterval now) {
    NSMutableArray<NSString *> *pruned = [NSMutableArray array];
    for (NSString *name in records) {
        id record = records[name];
        id opened = [record isKindOfClass:NSDictionary.class] ? ((NSDictionary *)record)[@"opened"] : nil;
        NSTimeInterval at = [opened isKindOfClass:NSNumber.class] ? [opened doubleValue] : 0;
        if (![kept containsObject:name] && now - at > kVibeLinkPruneAgeSeconds) {
            [pruned addObject:name];
        }
    }
    [pruned sortUsingSelector:@selector(compare:)];
    return pruned;
}

#pragma mark - Failures

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

// The probe's deadline, from the request to its first bytes. Redirects and
// resends count toward it. Past it the probe fails as its host's network
// failure. A public server that sends nothing for 15 s is down for practical
// purposes. A local host gets twice as long. It may be a NAS spinning up its
// disks. It may sit behind the system's local-network prompt, which holds the
// first request while the user reads it. The user can cancel sooner.
static const NSTimeInterval kVibeLinkProbeTimeoutPublic = 15;
static const NSTimeInterval kVibeLinkProbeTimeoutLocal = 30;

static inline NSTimeInterval VibeLinkProbeTimeout(NSString *_Nullable host) {
    return VibeLinkHostIsLocal(host) ? kVibeLinkProbeTimeoutLocal : kVibeLinkProbeTimeoutPublic;
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
