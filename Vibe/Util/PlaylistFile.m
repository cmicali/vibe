//
//  PlaylistFile.m
//  Vibe
//

#import "PlaylistFile.h"

#include <string.h>

@implementation PlaylistFile

+ (BOOL)isPlaylistExtension:(NSString *)extension {
    return [extension isEqualToString:@"cue"]
            || [extension isEqualToString:@"m3u"]
            || [extension isEqualToString:@"m3u8"];
}

+ (NSString *)textFromData:(NSData *)data {
    if (data.length == 0) {
        return nil;
    }
    const uint8_t *bytes = data.bytes;
    if (data.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
        if (text) {
            return text;
        }
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text && data.length >= 2 && memchr(bytes, 0, data.length)) {
        // A NUL byte occurs in no single-byte text encoding: this is BOM-less
        // UTF-16 (some Windows writers). The zeros sit on the high half of
        // each code unit, so their side tells the byte order — the CP1252
        // backstop would otherwise render it as NUL-riddled mojibake.
        NSUInteger evenNULs = 0, oddNULs = 0;
        for (NSUInteger i = 0; i + 1 < data.length; i += 2) {
            if (bytes[i] == 0) evenNULs++;
            if (bytes[i + 1] == 0) oddNULs++;
        }
        text = [[NSString alloc] initWithData:data
                                     encoding:oddNULs >= evenNULs
                                              ? NSUTF16LittleEndianStringEncoding
                                              : NSUTF16BigEndianStringEncoding];
    }
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
    }
    if (!text) {
        // Latin-1 maps every byte, so this cannot fail; mojibake in an odd
        // filename beats dropping the whole playlist.
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if ([text hasPrefix:@"\uFEFF"]) {
        text = [text substringFromIndex:1];
    }
    return text;
}

// Windows path separators; a genuine backslash in a filename is rarer than a
// Windows-authored playlist by orders of magnitude.
static NSString *NormalizePathSeparators(NSString *name) {
    return [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
}

#pragma mark - CUE

// The audio-type keywords the FILE line may end with. Only unquoted names need
// the strip; a quoted name is exact.
static BOOL IsCueFileTypeKeyword(NSString *token) {
    static NSSet<NSString *> *keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = [NSSet setWithObjects:@"WAVE", @"MP3", @"AIFF", @"BINARY", @"MOTOROLA", @"FLAC", nil];
    });
    return [keywords containsObject:token.uppercaseString];
}

+ (NSArray<NSString *> *)cueFileEntriesInText:(NSString *)text {
    NSMutableArray<NSString *> *entries = [NSMutableArray new];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceCharacterSet;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:whitespace];
        if (trimmed.length < 5 || [trimmed compare:@"FILE " options:NSCaseInsensitiveSearch
                                             range:NSMakeRange(0, 5)] != NSOrderedSame) {
            return;
        }
        NSString *rest = [[trimmed substringFromIndex:5] stringByTrimmingCharactersInSet:whitespace];
        NSString *name = nil;
        if ([rest hasPrefix:@"\""]) {
            NSRange close = [rest rangeOfString:@"\"" options:0 range:NSMakeRange(1, rest.length - 1)];
            name = close.location == NSNotFound
                    ? [rest substringFromIndex:1] // unterminated quote: take the rest
                    : [rest substringWithRange:NSMakeRange(1, close.location - 1)];
        }
        else {
            // Unquoted. Sloppy writers leave spaces in here too, so take the
            // whole remainder and strip a trailing type keyword if present.
            name = rest;
            NSRange lastSpace = [name rangeOfCharacterFromSet:whitespace options:NSBackwardsSearch];
            if (lastSpace.location != NSNotFound
                    && IsCueFileTypeKeyword([name substringFromIndex:NSMaxRange(lastSpace)])) {
                name = [[name substringToIndex:lastSpace.location] stringByTrimmingCharactersInSet:whitespace];
            }
        }
        name = NormalizePathSeparators(name);
        if (name.length == 0) {
            return;
        }
        if (entries.count > 0 && [entries.lastObject caseInsensitiveCompare:name] == NSOrderedSame) {
            return;
        }
        [entries addObject:name];
    }];
    return entries;
}

#pragma mark - M3U

+ (NSArray<NSString *> *)m3uEntriesInText:(NSString *)text {
    NSMutableArray<NSString *> *entries = [NSMutableArray new];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceCharacterSet;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *entry = [line stringByTrimmingCharactersInSet:whitespace];
        if (entry.length == 0 || [entry hasPrefix:@"#"]) {
            return;
        }
        if ([entry rangeOfString:@"://"].location != NSNotFound) {
            // A URL. file:// reduces to its path (M3U8 writers percent-encode);
            // any other scheme is a stream, which the player does not do.
            if (![entry.lowercaseString hasPrefix:@"file://"]) {
                return;
            }
            NSString *path = [NSURL URLWithString:entry].path;
            if (path.length == 0) {
                // Sloppy writers emit file:// URLs with raw spaces, which
                // NSURL refuses outright. Strip the scheme (and the optional
                // localhost authority) and take the remainder as a path,
                // percent-decoding what does decode.
                NSString *rest = [entry substringFromIndex:7];
                if ([rest.lowercaseString hasPrefix:@"localhost/"]) {
                    rest = [rest substringFromIndex:9];
                }
                path = rest.stringByRemovingPercentEncoding ?: rest;
            }
            if (path.length == 0) {
                return;
            }
            entry = path;
        }
        entry = NormalizePathSeparators(entry);
        if (entry.length > 0) {
            [entries addObject:entry];
        }
    }];
    return entries;
}

#pragma mark - Resolution

// Fallback rungs for one entry, in order: the named path as written, its
// basename beside the playlist (rescues Windows-absolute-path entries), then
// both of those again under each alternate audio extension (rescues a rip
// transcoded after the sheet was written — the cue says .wav, the files are
// now .flac). First readable candidate wins; readable nowhere returns the
// primary so the caller can tell sandbox denial from a missing file.
static NSURL *ResolveEntry(NSString *entry, NSURL *dir, NSFileManager *fileManager,
                           NSMutableDictionary<NSString *, NSNumber *> *dirReachable) {
    NSURL *primary = [entry hasPrefix:@"/"]
            ? [NSURL fileURLWithPath:entry]
            : [dir URLByAppendingPathComponent:entry].URLByStandardizingPath;
    NSURL *beside = [dir URLByAppendingPathComponent:entry.lastPathComponent];
    NSMutableArray<NSURL *> *candidates = [NSMutableArray arrayWithObject:primary];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:primary.path];
    void (^addCandidate)(NSURL *) = ^(NSURL *url) {
        if (url && ![seen containsObject:url.path]) {
            [seen addObject:url.path];
            [candidates addObject:url];
        }
    };
    addCandidate(beside);
    static NSArray<NSString *> *alternateExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        alternateExtensions = @[@"wav", @"aif", @"aiff", @"flac", @"mp3"];
    });
    // One readability probe of the primary's folder gates its five
    // alternate-extension candidates: a sheet of absolute paths into a
    // missing or unreachable volume then costs one stat per entry instead of
    // six. The probe is memoized per directory across the pass — on a dead
    // mount it blocks for an automounter timeout, and a list of absolute
    // paths into one folder must pay that once, not once per entry. The
    // beside candidates live in the playlist's own folder, which was just
    // read, so they stay unconditional.
    NSString *primaryDir = primary.URLByDeletingLastPathComponent.path;
    NSNumber *cached = dirReachable[primaryDir];
    BOOL primaryDirReachable = cached ? cached.boolValue
                                      : [fileManager isReadableFileAtPath:primaryDir];
    if (!cached && primaryDir) {
        dirReachable[primaryDir] = @(primaryDirReachable);
    }
    for (NSString *extension in alternateExtensions) {
        if (primaryDirReachable) {
            addCandidate([primary.URLByDeletingPathExtension URLByAppendingPathExtension:extension]);
        }
        addCandidate([beside.URLByDeletingPathExtension URLByAppendingPathExtension:extension]);
    }
    for (NSURL *candidate in candidates) {
        if ([fileManager isReadableFileAtPath:candidate.path]) {
            return candidate;
        }
    }
    return primary;
}

+ (NSArray<NSURL *> *)resolvedFileURLsForPlaylistAtURL:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSString *text = data ? [self textFromData:data] : nil;
    if (!text) {
        return @[];
    }
    NSArray<NSString *> *entries = [url.pathExtension.lowercaseString isEqualToString:@"cue"]
            ? [self cueFileEntriesInText:text]
            : [self m3uEntriesInText:text];
    NSURL *dir = url.URLByDeletingLastPathComponent;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:entries.count];
    NSMutableDictionary<NSString *, NSNumber *> *dirReachable = [NSMutableDictionary new];
    for (NSString *entry in entries) {
        [urls addObject:ResolveEntry(entry, dir, fileManager, dirReachable)];
    }
    return urls;
}

@end
