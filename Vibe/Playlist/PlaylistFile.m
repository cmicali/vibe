//
//  PlaylistFile.m
//  Vibe
//

#import "PlaylistFile.h"

#import "PlayableExtensions.h"

#include <string.h>

@implementation PlaylistFile

+ (BOOL)isPlaylistExtension:(NSString *)extension {
    return [extension isEqualToString:@"cue"]
            || [extension isEqualToString:@"m3u"]
            || [extension isEqualToString:@"m3u8"];
}

// NULs on the even and odd halves of the byte pairs. Both UTF-16 tests below
// are decided from these two counts alone, so they are counted in one place;
// the tests differ only in how strict they are, which is the point of keeping
// them apart.
static void CountHalfNULs(const uint8_t *bytes, NSUInteger length,
                          NSUInteger *evenNULs, NSUInteger *oddNULs) {
    *evenNULs = 0;
    *oddNULs = 0;
    for (NSUInteger i = 0; i + 1 < length; i += 2) {
        if (bytes[i] == 0) (*evenNULs)++;
        if (bytes[i + 1] == 0) (*oddNULs)++;
    }
}

// A byte order for BOM-less UTF-16 (some Windows writers), or 0 for "not
// UTF-16". Latin-script text puts a NUL on the high half of nearly every code
// unit and nothing else does, so a clear majority on one side with none at all
// on the other is the signature. Requiring the other side to be empty is what
// keeps a lone stray NUL in a corrupted UTF-8 file from being read as UTF-16.
static NSStringEncoding BOMlessUTF16Encoding(const uint8_t *bytes, NSUInteger length) {
    if (length < 4 || (length % 2) != 0) {
        return 0;
    }
    NSUInteger units = length / 2, evenNULs = 0, oddNULs = 0;
    CountHalfNULs(bytes, length, &evenNULs, &oddNULs);
    if (oddNULs * 2 >= units && evenNULs == 0) {
        return NSUTF16LittleEndianStringEncoding;
    }
    if (evenNULs * 2 >= units && oddNULs == 0) {
        return NSUTF16BigEndianStringEncoding;
    }
    return 0;
}

// The looser twin of the test above, for data that reached the fallback rungs:
// the strict form already declined it — an odd length, or NULs on both halves
// — so this only picks the likelier side rather than asking for a clean
// signature.
static NSStringEncoding LikelyUTF16Encoding(const uint8_t *bytes, NSUInteger length) {
    NSUInteger evenNULs = 0, oddNULs = 0;
    CountHalfNULs(bytes, length, &evenNULs, &oddNULs);
    return oddNULs >= evenNULs ? NSUTF16LittleEndianStringEncoding
                               : NSUTF16BigEndianStringEncoding;
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
    // TRAP: this has to be decided BEFORE the UTF-8 attempt, not after it
    // fails. UTF-16-encoded ASCII — which is what a sheet of plain filenames
    // is — carries no byte above 0x7F, so it decodes as UTF-8 *successfully*,
    // into text with a NUL between every character. No line then matches
    // anything and the playlist reads as empty. Only a non-ASCII filename
    // makes the UTF-8 decode fail, which is why the fallback below cannot
    // carry this on its own.
    NSString *text = nil;
    NSStringEncoding bomless = BOMlessUTF16Encoding(bytes, data.length);
    if (bomless) {
        text = [[NSString alloc] initWithData:data encoding:bomless];
    }
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    if (!text && data.length >= 2 && memchr(bytes, 0, data.length)) {
        // A NUL byte occurs in no single-byte text encoding: this is BOM-less
        // UTF-16 (some Windows writers). The zeros sit on the high half of
        // each code unit, so their side tells the byte order — the CP1252
        // backstop would otherwise render it as NUL-riddled mojibake.
        text = [[NSString alloc] initWithData:data
                                     encoding:LikelyUTF16Encoding(bytes, data.length)];
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

// TRAP: a path cannot hold a NUL, and an unpaired surrogate is not text at
// all, but both reach us — from a file truncated mid-write, from one written
// as UTF-16 and read as something else, from a %00 in a file:// URL. NSURL
// answers *nil* for such a component, and a nil candidate takes the whole open
// down with an exception on a background expansion worker. They are dropped
// here, while the name is still a string: what is left either names the file
// or resolves to nothing, and neither crashes.
static NSString *StrippedOfUnpathableCharacters(NSString *name) {
    NSUInteger length = name.length;
    BOOL suspect = NO;
    for (NSUInteger i = 0; i < length && !suspect; i++) {
        unichar unit = [name characterAtIndex:i];
        suspect = (unit == 0 || (unit >= 0xD800 && unit <= 0xDFFF));
    }
    if (!suspect) {
        return name;
    }
    unichar *units = calloc(length, sizeof(unichar));
    if (!units) {
        return name;
    }
    [name getCharacters:units range:NSMakeRange(0, length)];
    // Compacted in place, which is safe because the write index never passes
    // the read index. A valid surrogate pair is copied whole — emoji in a
    // filename are ordinary text and take this path too.
    NSUInteger out = 0;
    for (NSUInteger i = 0; i < length; i++) {
        unichar unit = units[i];
        if (unit == 0 || (unit >= 0xDC00 && unit <= 0xDFFF)) {
            continue;
        }
        if (unit >= 0xD800 && unit <= 0xDBFF) {
            if (i + 1 < length && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF) {
                units[out++] = unit;
                units[out++] = units[i + 1];
                i++;
            }
            continue;
        }
        units[out++] = unit;
    }
    NSString *clean = [NSString stringWithCharacters:units length:out];
    free(units);
    return clean;
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
        // Any whitespace after the keyword: sloppy writers tab-delimit too,
        // and a missed FILE line is the parser's worst case — an empty sheet.
        if (trimmed.length < 5
                || [trimmed compare:@"FILE" options:NSCaseInsensitiveSearch
                              range:NSMakeRange(0, 4)] != NSOrderedSame
                || ![whitespace characterIsMember:[trimmed characterAtIndex:4]]) {
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
        name = StrippedOfUnpathableCharacters(NormalizePathSeparators(name));
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
        entry = StrippedOfUnpathableCharacters(NormalizePathSeparators(entry));
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
    // Both constructors answer nil for a component no path can hold; the
    // parsers strip those, and this is the backstop for any other caller.
    // Nothing can be resolved without a primary, so the entry has no URL.
    if (!primary.path) {
        return nil;
    }
    NSURL *beside = [dir URLByAppendingPathComponent:entry.lastPathComponent];
    NSMutableArray<NSURL *> *candidates = [NSMutableArray arrayWithObject:primary];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:primary.path];
    void (^addCandidate)(NSURL *) = ^(NSURL *url) {
        // The path, not the URL, is the identity here, and it is nil for a
        // component no path can hold — the same case the primary is checked
        // for above. A nil there would raise inside the set.
        NSString *path = url.path;
        if (path && ![seen containsObject:path]) {
            [seen addObject:path];
            [candidates addObject:url];
        }
    };
    addCandidate(beside);
    // One readability probe of the primary's folder gates its alternate-extension
    // candidates: a sheet of absolute paths into a missing or unreachable volume
    // then costs one stat per entry instead of one per playable spelling. The
    // probe is memoized per directory across the pass — on a dead mount it blocks
    // for an automounter timeout, and a list of absolute paths into one folder
    // must pay that once, not once per entry. The beside candidates live in the
    // playlist's own folder, which was just read, so they stay unconditional.
    NSString *primaryDir = primary.URLByDeletingLastPathComponent.path;
    BOOL primaryDirReachable = NO;
    if (primaryDir) {
        NSNumber *cached = dirReachable[primaryDir];
        primaryDirReachable = cached != nil ? cached.boolValue
                                           : [fileManager isReadableFileAtPath:primaryDir];
        if (cached == nil) {
            dirReachable[primaryDir] = @(primaryDirReachable);
        }
    }
    for (NSString *extension in PlayableExtensions.ordered) {
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
        NSURL *resolved = ResolveEntry(entry, dir, fileManager, dirReachable);
        if (resolved) {
            [urls addObject:resolved];
        }
    }
    return urls;
}

@end
