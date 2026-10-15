//
//  GoogleDriveRules.h
//  Vibe (iOS)
//
//  The Google Drive decisions that need no network and no disk: the
//  sign-in's addresses, the API's addresses and query, how an answer and an
//  entry read, the local name each file takes, and the mtime that keeps the
//  cache key honest. What every account shares is AccountRules.h.
//  Header-only and Foundation-only so the macOS suite tests it.
//
//  What sets Drive apart from Dropbox, and why these rules exist:
//  - A file is its id. Names repeat within a folder, and a name can hold
//    '/'. So every request names an id, and a local name is a slot the
//    folder's index records against that id (VibeGoogleDriveSlots).
//  - A media response states no version. The client looks the file up
//    before each request and takes its md5Checksum as the version
//    (GoogleDriveClient).
//  - A client may keep modifiedTime across a new upload, and Vibe's cache
//    key is size plus mtime. So the version, not the date, decides whether a
//    file changed, and a changed file whose date did not move is dated past
//    its old self (VibeGoogleDriveStamp).
//

#ifndef GoogleDriveRules_h
#define GoogleDriveRules_h

#import <Foundation/Foundation.h>

#import "AccountRules.h"
#import "HTTPTransferRules.h"
#import "PlaylistFile.h"

#include <time.h>

NS_ASSUME_NONNULL_BEGIN

#define VIBE_GOOGLE_DRIVE_API_BASE    @"https://www.googleapis.com/drive/v3/"
#define VIBE_GOOGLE_DRIVE_TOKEN_URL   @"https://oauth2.googleapis.com/token"
#define VIBE_GOOGLE_DRIVE_REVOKE_URL  @"https://oauth2.googleapis.com/revoke"
#define VIBE_GOOGLE_DRIVE_AUTHORIZE   @"https://accounts.google.com/o/oauth2/v2/auth"
// Read-only, the whole account: a file browser cannot work from picked
// files alone (docs/future/ios-google-drive.md has the scope's review).
#define VIBE_GOOGLE_DRIVE_SCOPE       @"https://www.googleapis.com/auth/drive.readonly"
#define VIBE_GOOGLE_DRIVE_FOLDER_TYPE @"application/vnd.google-apps.folder"
// What a listing and a search ask of each file, and nothing more.
#define VIBE_GOOGLE_DRIVE_FILE_FIELDS @"id,name,mimeType,size,modifiedTime,md5Checksum,headRevisionId,parents"
// What the lookup before each download or ranged read asks.
#define VIBE_GOOGLE_DRIVE_LOOKUP_FIELDS @"id,size,modifiedTime,md5Checksum,headRevisionId"

#pragma mark - OAuth

// An iOS OAuth client's redirect scheme is its id reversed:
// "123-abc.apps.googleusercontent.com" redirects to
// "com.googleusercontent.apps.123-abc". Google registers it with the client,
// so nothing in Info.plist names it.
static inline NSString *VibeGoogleDriveCallbackScheme(NSString *clientID) {
    NSArray<NSString *> *parts = [clientID componentsSeparatedByString:@"."];
    return [parts.reverseObjectEnumerator.allObjects componentsJoinedByString:@"."];
}

// Sent twice, to the sign-in page and with the code; Google refuses a
// mismatch.
static inline NSString *VibeGoogleDriveRedirectURI(NSString *clientID) {
    return [VibeGoogleDriveCallbackScheme(clientID) stringByAppendingString:@":/oauth2redirect"];
}

// An installed app's request: PKCE and no client secret. Its code exchange
// grants a refresh token.
static inline NSURL *VibeGoogleDriveAuthorizeURL(NSString *clientID,
                                                 NSString *codeChallenge,
                                                 NSString *state) {
    NSURLComponents *components = [NSURLComponents componentsWithString:VIBE_GOOGLE_DRIVE_AUTHORIZE];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client_id" value:clientID],
        [NSURLQueryItem queryItemWithName:@"redirect_uri" value:VibeGoogleDriveRedirectURI(clientID)],
        [NSURLQueryItem queryItemWithName:@"response_type" value:@"code"],
        [NSURLQueryItem queryItemWithName:@"scope" value:VIBE_GOOGLE_DRIVE_SCOPE],
        [NSURLQueryItem queryItemWithName:@"code_challenge" value:codeChallenge],
        [NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
        [NSURLQueryItem queryItemWithName:@"state" value:state],
    ];
    return components.URL;
}

#pragma mark - Wire

// An API address with its query (VibeAccountQueryString).
static inline NSURL *VibeGoogleDriveURL(NSString *path, NSDictionary<NSString *, NSString *> *query) {
    NSURLComponents *components = [NSURLComponents componentsWithString:[VIBE_GOOGLE_DRIVE_API_BASE stringByAppendingString:path]];
    components.percentEncodedQuery = query.count > 0 ? VibeAccountQueryString(query) : nil;
    return components.URL;
}

// A value inside a query string's quotes: a backslash and a quote are
// escaped with a backslash.
static inline NSString *VibeGoogleDriveQueryLiteral(NSString *text) {
    NSString *escaped = [text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
}

// files.list's q for a folder's children. Ids hold only [A-Za-z0-9_-], and
// "root" names My Drive.
static inline NSString *VibeGoogleDriveChildrenQuery(NSString *folderID) {
    return [NSString stringWithFormat:@"'%@' in parents and trashed = false", VibeGoogleDriveQueryLiteral(folderID)];
}

// files.list's q for a search. Drive matches a name by the prefix of each of
// its words, not anywhere inside it.
static inline NSString *VibeGoogleDriveSearchQuery(NSString *text) {
    return [NSString stringWithFormat:@"name contains '%@' and trashed = false", VibeGoogleDriveQueryLiteral(text)];
}

// The first reason an API error names ("rateLimitExceeded"), nil for none.
static inline NSString *_Nullable VibeGoogleDriveErrorReason(NSDictionary *_Nullable body) {
    NSDictionary *error = [body[@"error"] isKindOfClass:NSDictionary.class] ? body[@"error"] : nil;
    NSArray *errors = [error[@"errors"] isKindOfClass:NSArray.class] ? error[@"errors"] : nil;
    NSDictionary *first = [errors.firstObject isKindOfClass:NSDictionary.class] ? errors.firstObject : nil;
    return [first[@"reason"] isKindOfClass:NSString.class] ? first[@"reason"] : nil;
}

// The one line a failure leaves in the log and the error. An API error is
// {"error": {"message", "errors": [{"reason"}]}}; an OAuth error is
// {"error", "error_description"}.
static inline NSString *VibeGoogleDriveErrorSummary(NSInteger status, NSDictionary *_Nullable body) {
    id error = body[@"error"];
    if ([error isKindOfClass:NSDictionary.class]) {
        NSString *message = [error[@"message"] isKindOfClass:NSString.class] ? error[@"message"] : nil;
        NSString *reason = VibeGoogleDriveErrorReason(body);
        if (message.length > 0) {
            return reason ? [NSString stringWithFormat:@"%@: %@", reason, message] : message;
        }
    }
    if ([error isKindOfClass:NSString.class] && ((NSString *)error).length > 0) {
        NSString *description = body[@"error_description"];
        return [description isKindOfClass:NSString.class] && description.length > 0
                ? [NSString stringWithFormat:@"%@: %@", error, description] : (NSString *)error;
    }
    return [NSString stringWithFormat:@"HTTP %ld", (long)status];
}

// A refusal Google asks to be retried later with backoff: a rate limit,
// which can answer 403 with its reason or 429, and a passing server error.
// A 403 for any other reason is the file's or the policy's, and stands.
static inline BOOL VibeGoogleDriveIsThrottle(NSInteger status, NSDictionary *_Nullable body) {
    if (status == 429 || status == 500 || status == 502 || status == 503 || status == 504) {
        return YES;
    }
    NSString *reason = VibeGoogleDriveErrorReason(body);
    return status == 403 && ([reason isEqualToString:@"rateLimitExceeded"]
                             || [reason isEqualToString:@"userRateLimitExceeded"]);
}

#pragma mark - Entries

static inline BOOL VibeGoogleDriveIsFolder(NSDictionary *entry) {
    return [entry[@"mimeType"] isEqual:VIBE_GOOGLE_DRIVE_FOLDER_TYPE];
}

// A file's size, -1 when it names none. The API writes an int64 as a JSON
// string.
static inline int64_t VibeGoogleDriveSizeOf(NSDictionary *_Nullable metadata) {
    id size = metadata[@"size"];
    if ([size isKindOfClass:NSString.class]) {
        return VibeHTTPParseLength(size);
    }
    long long value = [size isKindOfClass:NSNumber.class] ? ((NSNumber *)size).longLongValue : -1;
    return value >= 0 ? value : -1;
}

// The version of a file's content: its md5Checksum, else its head revision.
// Nil when it names neither, and such a file is never resumed.
static inline NSString *_Nullable VibeGoogleDriveVersionOf(NSDictionary *_Nullable metadata) {
    NSString *checksum = metadata[@"md5Checksum"];
    if ([checksum isKindOfClass:NSString.class] && checksum.length > 0) {
        return checksum;
    }
    NSString *revision = metadata[@"headRevisionId"];
    return [revision isKindOfClass:NSString.class] && revision.length > 0 ? revision : nil;
}

// Which entries the mirror keeps: folders, and the files whose name
// AccountRules.h mirrors and that have bytes. A shortcut or a Google Docs
// file states no size, and its media download is refused.
static inline BOOL VibeGoogleDriveEntryIsMirrored(NSDictionary *entry, NSSet<NSString *> *playableExtensions) {
    NSString *name = entry[@"name"];
    if (![entry[@"id"] isKindOfClass:NSString.class] || ![name isKindOfClass:NSString.class] || name.length == 0) {
        return NO;
    }
    return VibeGoogleDriveIsFolder(entry)
            || (VibeAccountNameIsMirrored(name, playableExtensions) && VibeGoogleDriveSizeOf(entry) >= 0);
}

// A search's answer as entries: folders and mirrored files other than CUE
// sheets, at most `limit`.
static inline NSArray<NSDictionary *> *VibeGoogleDriveSearchEntries(NSDictionary *_Nullable result,
                                                                     NSSet<NSString *> *playableExtensions,
                                                                     NSUInteger limit) {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSArray *files = [result[@"files"] isKindOfClass:NSArray.class] ? result[@"files"] : nil;
    for (NSDictionary *file in files) {
        if (entries.count >= limit) {
            break;
        }
        if (![file isKindOfClass:NSDictionary.class] || !VibeGoogleDriveEntryIsMirrored(file, playableExtensions)) {
            continue;
        }
        NSString *name = file[@"name"];
        if (!VibeGoogleDriveIsFolder(file) && [PlaylistFile isCueExtension:name.pathExtension.lowercaseString]) {
            continue;
        }
        [entries addObject:file];
    }
    return entries;
}

// The one parent a file has in My Drive, nil for none: an item only shared
// with the user has no parent the user can see.
static inline NSString *_Nullable VibeGoogleDriveParentOf(NSDictionary *entry) {
    NSArray *parents = [entry[@"parents"] isKindOfClass:NSArray.class] ? entry[@"parents"] : nil;
    return [parents.firstObject isKindOfClass:NSString.class] ? parents.firstObject : nil;
}

#pragma mark - Local names

// The longest local name in UTF-8 bytes before a copy's suffix. Room is left
// for the hidden part file's and placeholder's own names, which add to it.
static const NSUInteger kVibeGoogleDriveNameMaxBytes = 200;

// A Drive name as a name here. '/' and NUL, which Drive allows and a file
// name cannot hold, become '-'. Leading dots go, since a hidden name here is
// a part file. The name is cut to kVibeGoogleDriveNameMaxBytes on a
// character boundary, keeping a file's extension. An empty result is "_".
static inline NSString *VibeGoogleDriveLocalBaseName(NSString *name, BOOL folder) {
    NSString *clean = [name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    clean = [clean stringByReplacingOccurrencesOfString:@"\0" withString:@"-"];
    while ([clean hasPrefix:@"."]) {
        clean = [clean substringFromIndex:1];
    }
    if ([clean lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kVibeGoogleDriveNameMaxBytes) {
        NSString *extension = folder ? @"" : clean.pathExtension;
        NSString *suffix = extension.length > 0 ? [@"." stringByAppendingString:extension] : @"";
        NSString *stem = extension.length > 0 ? clean.stringByDeletingPathExtension : clean;
        NSUInteger suffixBytes = [suffix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger budget = suffixBytes < kVibeGoogleDriveNameMaxBytes ? kVibeGoogleDriveNameMaxBytes - suffixBytes : 0;
        __block NSUInteger end = 0;
        __block NSUInteger bytes = 0;
        [stem enumerateSubstringsInRange:NSMakeRange(0, stem.length)
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
        clean = [[stem substringToIndex:end] stringByAppendingString:budget > 0 ? suffix : @""];
    }
    return clean.length > 0 ? clean : @"_";
}

// The name of a slot's copy: "Song (2).mp3", "Song (3).mp3", a folder's
// "Live (2)". The first copy is the name itself.
static inline NSString *VibeGoogleDriveCopyName(NSString *base, NSUInteger copy, BOOL folder) {
    if (copy <= 1) {
        return base;
    }
    NSString *extension = folder ? @"" : base.pathExtension;
    NSString *stem = extension.length > 0 ? base.stringByDeletingPathExtension : base;
    NSString *named = [NSString stringWithFormat:@"%@ (%lu)", stem, (unsigned long)copy];
    return extension.length > 0 ? ([named stringByAppendingPathExtension:extension] ?: named) : named;
}

// A slot's name without the copy suffix it was given.
static inline NSString *VibeGoogleDriveCopyBase(NSString *slot, BOOL folder) {
    NSString *extension = folder ? @"" : slot.pathExtension;
    NSString *stem = extension.length > 0 ? slot.stringByDeletingPathExtension : slot;
    NSRange open = [stem rangeOfString:@" (" options:NSBackwardsSearch];
    if ([stem hasSuffix:@")"] && open.location != NSNotFound) {
        NSRange digits = NSMakeRange(NSMaxRange(open), stem.length - NSMaxRange(open) - 1);
        NSString *number = [stem substringWithRange:digits];
        if (number.length > 0 && [number rangeOfCharacterFromSet:
                [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location == NSNotFound) {
            stem = [stem substringToIndex:open.location];
        }
    }
    return extension.length > 0 ? ([stem stringByAppendingPathExtension:extension] ?: stem) : stem;
}

// Each entry's local name, by id. An entry keeps the name it had (previous,
// id → name) while that name still fits its Drive name, so a listing's order
// never renames a file. A new entry, or a renamed one, takes its base name,
// else the first copy free. Names are compared by VibeAccountIndexKey, so
// two names one volume would merge never share a slot. New entries take
// their slots in id order, so the same listing names them the same way
// twice. Each entry is a Drive entry, as listed.
static inline NSDictionary<NSString *, NSString *> *VibeGoogleDriveSlots(NSArray<NSDictionary *> *entries,
                                                                         NSDictionary<NSString *, NSString *> *previous) {
    NSMutableDictionary<NSString *, NSString *> *slots = [NSMutableDictionary dictionaryWithCapacity:entries.count];
    NSMutableSet<NSString *> *used = [NSMutableSet setWithCapacity:entries.count];
    NSMutableArray<NSDictionary *> *fresh = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        NSString *identifier = entry[@"id"];
        BOOL folder = VibeGoogleDriveIsFolder(entry);
        NSString *base = VibeGoogleDriveLocalBaseName(entry[@"name"], folder);
        NSString *had = previous[identifier];
        NSString *key = had ? VibeAccountIndexKey(had) : nil;
        BOOL fits = had && ([key isEqualToString:VibeAccountIndexKey(base)]
                            || [VibeAccountIndexKey(VibeGoogleDriveCopyBase(had, folder)) isEqualToString:VibeAccountIndexKey(base)]);
        if (fits && ![used containsObject:key] && !slots[identifier]) {
            slots[identifier] = had;
            [used addObject:key];
        }
        else if (!slots[identifier]) {
            [fresh addObject:entry];
        }
    }
    [fresh sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *first = a[@"id"];
        return [first compare:b[@"id"]];
    }];
    for (NSDictionary *entry in fresh) {
        NSString *identifier = entry[@"id"];
        if (slots[identifier]) {
            continue;   // the same id twice in one listing
        }
        BOOL folder = VibeGoogleDriveIsFolder(entry);
        NSString *base = VibeGoogleDriveLocalBaseName(entry[@"name"], folder);
        for (NSUInteger copy = 1;; copy++) {
            NSString *candidate = VibeGoogleDriveCopyName(base, copy, folder);
            NSString *key = VibeAccountIndexKey(candidate);
            if (![used containsObject:key]) {
                slots[identifier] = candidate;
                [used addObject:key];
                break;
            }
        }
    }
    return slots;
}

#pragma mark - The cache key

// The mtime a changed file's placeholder or download takes. Vibe's cache key
// is size plus mtime, and Drive lets a client keep modifiedTime across a new
// upload. So a new version is dated by Drive unless that would not move it
// past the version the file held here: then it is dated one second past
// that. The stamp only ever grows per file, so no version reuses another's
// key. A file new here takes Drive's date.
static inline time_t VibeGoogleDriveStamp(time_t remoteModified, BOOL present, time_t localModified) {
    time_t remote = remoteModified >= 0 ? remoteModified : 0;
    if (present && remote <= localModified) {
        return localModified + 1;
    }
    return remote;
}

NS_ASSUME_NONNULL_END

#endif
