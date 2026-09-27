//
//  PlaylistFile.m
//  Vibe
//

#import "PlaylistFile.h"

#import "AudioTrack.h"
#import "PlayableExtensions.h"

#include <string.h>

NSString *const kVibeLastPlaylistCurrentIndexKey = @"VibeLastPlaylistCurrentIndex";

@implementation PlaylistFile

+ (BOOL)saveSessionTracks:(NSArray<AudioTrack *> *)tracks currentIndex:(NSUInteger)index
                 enabled:(BOOL)enabled toURL:(NSURL *)url defaults:(NSUserDefaults *)defaults
                   write:(BOOL (^)(NSError **))write error:(NSError **)error {
    if (!enabled || tracks.count == 0) {
        [self removeSessionAtURL:url defaults:defaults];
        return YES;
    }
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL saved = write ? write(error) : [self writeM3UForTracks:tracks relativeToDirectory:nil toURL:url error:error];
    if (!saved) {
        [self removeSessionAtURL:url defaults:defaults];
        return NO;
    }
    [defaults setInteger:(NSInteger)MIN(index, tracks.count - 1) forKey:kVibeLastPlaylistCurrentIndexKey];
    return YES;
}

+ (void)removeSessionAtURL:(NSURL *)url defaults:(NSUserDefaults *)defaults {
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    [defaults removeObjectForKey:kVibeLastPlaylistCurrentIndexKey];
}

+ (BOOL)restoreSessionAtURL:(NSURL *)url enabled:(BOOL)enabled defaults:(NSUserDefaults *)defaults
                     load:(void (^)(NSArray<NSURL *> *, NSUInteger, BOOL))load {
    if (!enabled) return NO;
    NSArray<NSURL *> *urls = [self fileURLsInM3UData:[NSData dataWithContentsOfURL:url]];
    if (urls.count == 0) return NO;
    NSInteger stored = [defaults integerForKey:kVibeLastPlaylistCurrentIndexKey];
    NSUInteger index = stored < 0 ? 0 : MIN((NSUInteger)stored, urls.count - 1);
    load(urls, index, YES);
    return YES;
}

+ (BOOL)isPlaylistExtension:(NSString *)extension {
    return [extension isEqualToString:@"cue"]
            || [extension isEqualToString:@"m3u"]
            || [extension isEqualToString:@"m3u8"];
}

// NULs on the even and odd halves of the byte pairs, the only input to both
// UTF-16 tests below.
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

// The looser twin, for data the strict test declined: picks the likelier side
// rather than asking for a clean signature.
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
    // TRAP: decide BOM-less UTF-16 BEFORE trying UTF-8. UTF-16 ASCII has no
    // byte above 0x7F, so it decodes as UTF-8 *successfully*, with a NUL
    // between every character, and the playlist reads as empty; the NUL
    // fallback below only sees files a non-ASCII name made UTF-8 reject.
    NSString *text = nil;
    NSStringEncoding bomless = BOMlessUTF16Encoding(bytes, data.length);
    if (bomless) {
        text = [[NSString alloc] initWithData:data encoding:bomless];
    }
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    if (!text && data.length >= 2 && memchr(bytes, 0, data.length)) {
        // No single-byte encoding holds a NUL, so this is UTF-16 the strict
        // test declined; CP1252 would render it as NUL-riddled mojibake.
        text = [[NSString alloc] initWithData:data
                                     encoding:LikelyUTF16Encoding(bytes, data.length)];
    }
    if (!text) {
        text = [[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
    }
    if (!text) {
        // Maps every byte, so this cannot fail: mojibake in one filename beats
        // dropping the whole playlist.
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

// TRAP: truncated and mis-encoded files carry NULs and unpaired surrogates.
// NSURL answers *nil* for such a component, and a nil candidate raises on the
// background expansion worker. Drop them while the name is still a string.
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
    // In place: the write index never passes the read index. A valid
    // surrogate pair (emoji) is copied whole.
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
            // TRAP: NSURL.path decodes %00 to a NUL on older Foundation and
            // keeps the literal %00 on macOS 26, so drop it before NSURL parses
            // the entry. Unambiguous: a literal "%00" in a name travels as %2500.
            entry = [entry stringByReplacingOccurrencesOfString:@"%00" withString:@""];
            NSString *path = [NSURL URLWithString:entry].path;
            if (path.length == 0) {
                // NSURL refuses the raw spaces sloppy writers emit: strip the
                // scheme and optional localhost and decode what decodes.
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

// Rungs in order: the named path, its basename beside the playlist (a
// Windows-absolute entry), then both under each playable extension (a rip
// transcoded after the sheet was written). First readable wins; readable
// nowhere returns the primary so the caller can tell sandbox denial from a
// missing file.
static NSURL *ResolveEntry(NSString *entry, NSURL *dir, NSFileManager *fileManager,
                           NSMutableDictionary<NSString *, NSNumber *> *dirReachable) {
    NSURL *primary = [entry hasPrefix:@"/"]
            ? [NSURL fileURLWithPath:entry]
            : [dir URLByAppendingPathComponent:entry].URLByStandardizingPath;
    // Backstop for a component the parsers' strip missed: no primary, no URL.
    if (!primary.path) {
        return nil;
    }
    NSURL *beside = [dir URLByAppendingPathComponent:entry.lastPathComponent];
    NSMutableArray<NSURL *> *candidates = [NSMutableArray arrayWithObject:primary];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:primary.path];
    void (^addCandidate)(NSURL *) = ^(NSURL *url) {
        // Keyed by path, which is nil for an unpathable component; a nil
        // would raise inside the set.
        NSString *path = url.path;
        if (path && ![seen containsObject:path]) {
            [seen addObject:path];
            [candidates addObject:url];
        }
    };
    addCandidate(beside);
    // One probe of the primary's folder, memoized per pass, gates its
    // alternate extensions: on a dead mount each probe blocks for an
    // automounter timeout, which a sheet into one folder must pay once. The
    // beside candidates are in the playlist's own, just-read folder.
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

+ (NSArray<NSURL *> *)fileURLsInM3UData:(NSData *)data {
    NSString *text = [self textFromData:data];
    NSArray<NSString *> *entries = text ? [self m3uEntriesInText:text] : @[];
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSString *entry in entries) {
        // isDirectory:NO, or fileURLWithPath: stats the path to decide.
        NSURL *url = [entry hasPrefix:@"/"] ? [NSURL fileURLWithPath:entry isDirectory:NO] : nil;
        if (url.path) {   // nil for a component no path can hold
            [urls addObject:url];
        }
    }
    return urls;
}

#pragma mark - M3U writing

// Relative under prefix, absolute otherwise.
// TRAP: every M3U reader trims whitespace, splits at newlines and skips a
// leading #, so a name any of those would mangle goes out as a
// percent-encoded file:// URL, which reads back whole (and absolute).
static NSString *M3UPathLine(NSString *path, NSString *_Nullable prefix) {
    NSString *line = prefix != nil && [path hasPrefix:prefix] ? [path substringFromIndex:prefix.length] : path;
    if ([line hasPrefix:@"#"]
            || [line rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound
            || ![[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] isEqualToString:line]) {
        return [NSURL fileURLWithPath:path isDirectory:NO].absoluteString;
    }
    return line;
}

// A literal " - ", not STR_LABEL_TRACK_ARTIST_TITLE: an interchange file must
// not change shape with the UI language. A newline becomes a space, or the
// tail would read as an entry line.
static NSString *M3UInfoName(AudioTrack *track) {
    NSString *artist = track.displayArtist;
    NSString *name = artist ? [NSString stringWithFormat:@"%@ - %@", artist, track.displayTitle]
                            : track.displayTitle;
    return [[name componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@" "];
}

+ (NSString *)m3uTextForTracks:(NSArray<AudioTrack *> *)tracks relativeToDirectory:(NSURL *)directory {
    // The trailing slash keeps /Music/Album from claiming /Music/Album2/x.mp3.
    // Both sides standardize alike, stat-free.
    NSString *dir = directory.path.stringByStandardizingPath;
    NSString *prefix = [dir hasSuffix:@"/"] ? dir : [dir stringByAppendingString:@"/"];
    NSMutableString *text = [NSMutableString stringWithString:@"#EXTM3U\n"];
    for (AudioTrack *track in tracks) {
        NSTimeInterval duration = track.duration;
        [text appendFormat:@"#EXTINF:%lld,%@\n%@\n",
                duration > 0 ? llround(duration) : -1LL,
                M3UInfoName(track),
                M3UPathLine(track.url.path.stringByStandardizingPath, prefix)];
    }
    return text;
}

+ (BOOL)writeM3UForTracks:(NSArray<AudioTrack *> *)tracks relativeToDirectory:(NSURL *)directory
                    toURL:(NSURL *)url error:(NSError **)error {
    NSString *text = [self m3uTextForTracks:tracks relativeToDirectory:directory];
    // Lossy: an unpaired surrogate from a malformed tag costs one character,
    // not the save.
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    return [data writeToURL:url options:NSDataWritingAtomic error:error];
}

+ (NSURL *)commonDirectoryForTracks:(NSArray<AudioTrack *> *)tracks {
    NSArray<NSString *> *common = nil;
    for (AudioTrack *track in tracks) {
        NSArray<NSString *> *components =
                track.url.path.stringByStandardizingPath.stringByDeletingLastPathComponent.pathComponents;
        if (!common) {
            common = components;
            continue;
        }
        NSUInteger shared = 0, limit = MIN(common.count, components.count);
        while (shared < limit && [common[shared] isEqualToString:components[shared]]) {
            shared++;
        }
        if (shared <= 1) {
            return nil;   // "/" alone: nothing deeper can be shared
        }
        if (shared < common.count) {
            common = [common subarrayWithRange:NSMakeRange(0, shared)];
        }
    }
    return common.count > 1 ? [NSURL fileURLWithPath:[NSString pathWithComponents:common] isDirectory:YES] : nil;
}

@end
