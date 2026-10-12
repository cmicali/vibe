//
//  PlaylistFile.m
//  Vibe
//

#import "PlaylistFile.h"
#import "PlaylistFileInternal.h"

#import "AudioTrack.h"
#import "PlayableExtensions.h"
#import "PlaybackIntent.h"

#include <string.h>

@implementation PlaylistFile

+ (BOOL)isCueExtension:(NSString *)extension {
    return [extension isEqualToString:@"cue"];
}

+ (BOOL)isM3UExtension:(NSString *)extension {
    return [extension isEqualToString:@"m3u"] || [extension isEqualToString:@"m3u8"];
}

+ (BOOL)isPlaylistExtension:(NSString *)extension {
    return [self isCueExtension:extension] || [self isM3UExtension:extension];
}

// The file decoded as playlist text; nil when unreadable.
NSString *VibeTextOfFile(NSURL *url) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    return data ? [PlaylistFile textFromData:data] : nil;
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
NSString *VibeNormalizePathSeparators(NSString *name) {
    return [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
}

// TRAP: truncated and mis-encoded files carry NULs and unpaired surrogates.
// NSURL answers *nil* for such a component, and a nil candidate raises on the
// background expansion worker. Drop them while the name is still a string.
NSString *VibeStrippedOfUnpathableCharacters(NSString *name) {
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

#pragma mark - M3U

static NSString *const kVibeCueDirective = @"#VIBE-CUE:";

// Each entry, with the #VIBE-CUE payload written just before it, if any: a
// directive belongs to the next entry line and to no other, a dropped one
// included.
static void EnumerateM3U(NSString *text, void (^block)(NSString *entry, NSString *_Nullable cue)) {
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceCharacterSet;
    __block NSString *cue = nil;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *entry = [line stringByTrimmingCharactersInSet:whitespace];
        if (entry.length == 0) {
            return;
        }
        if ([entry hasPrefix:@"#"]) {
            if ([entry hasPrefix:kVibeCueDirective]) {
                cue = [entry substringFromIndex:kVibeCueDirective.length];
            }
            return;
        }
        NSString *entryCue = cue;
        cue = nil;
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
        entry = VibeStrippedOfUnpathableCharacters(VibeNormalizePathSeparators(entry));
        if (entry.length > 0) {
            block(entry, entryCue);
        }
    }];
}

+ (NSArray<NSString *> *)m3uEntriesInText:(NSString *)text {
    NSMutableArray<NSString *> *entries = [NSMutableArray new];
    EnumerateM3U(text, ^(NSString *entry, NSString *cue) {
        [entries addObject:entry];
    });
    return entries;
}

// Title and performer are percent-encoded so neither holds the separator or a
// newline; spaces stay readable, and only a line's ends are trimmed.
static NSCharacterSet *CueFieldAllowedCharacters(void) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
        [set removeCharactersInString:@","];
        [set addCharactersInString:@" "];
        allowed = [set copy];
    });
    return allowed;
}

// The #VIBE-CUE payload: "<track>,<start>,<end>,<title>,<performer>,<sheet
// URL>", the window in CD frames. The URL is last, so its own commas need no
// escape.
static NSString *CuePayload(AudioTrack *track) {
    NSString *title = [track.cueTitle ?: @"" stringByAddingPercentEncodingWithAllowedCharacters:CueFieldAllowedCharacters()];
    NSString *performer = [track.cuePerformer ?: @"" stringByAddingPercentEncodingWithAllowedCharacters:CueFieldAllowedCharacters()];
    return [NSString stringWithFormat:@"%ld,%lu,%lu,%@,%@,%@", (long)track.cueTrackNumber,
            (unsigned long)track.cueStart, (unsigned long)track.cueEnd, title ?: @"", performer ?: @"",
            track.cueSheetURL.absoluteString ?: @""];
}

// The entry's file as that row; a plain row without a payload, or with one
// that does not parse into a playable window.
static AudioTrack *RowForEntry(NSURL *url, NSString *_Nullable cue) {
    NSArray<NSString *> *fields = [cue componentsSeparatedByString:@","];
    if (fields.count < 6) {
        return [AudioTrack withURL:url];
    }
    long long start = fields[1].longLongValue;
    long long end = fields[2].longLongValue;
    if (start < 0 || end < 0 || (end > 0 && end <= start)) {
        return [AudioTrack withURL:url];
    }
    NSString *title = fields[3].stringByRemovingPercentEncoding;
    NSString *performer = fields[4].stringByRemovingPercentEncoding;
    NSString *sheet = [[fields subarrayWithRange:NSMakeRange(5, fields.count - 5)] componentsJoinedByString:@","];
    NSURL *sheetURL = sheet.length ? [NSURL URLWithString:sheet] : nil;
    return [[AudioTrack alloc] initWithURL:url cueStart:(NSUInteger)start cueEnd:(NSUInteger)end
                                     title:title.length ? title : nil
                                 performer:performer.length ? performer : nil
                                     sheet:sheetURL.isFileURL ? sheetURL : nil
                               trackNumber:fields[0].integerValue];
}

#pragma mark - Resolution

NSURL *VibeKnownFileAtPath(NSString *path, NSDictionary<NSString *, NSArray<NSURL *> *> *knownFiles) {
    if (!path) {
        return nil;
    }
    NSArray<NSURL *> *matches = knownFiles[[PlaylistFile knownFileKeyForPath:path]];
    for (NSURL *url in matches) {
        if ([url.path isEqualToString:path]) {
            return url;
        }
    }
    return matches.count == 1 ? matches.firstObject : nil;
}

// Rungs in order: the named path, its basename beside the playlist (a
// Windows-absolute entry), then both under each playable extension (a rip
// transcoded after the sheet was written). First found wins, and each rung is
// built only once the ones before it failed, since the first usually holds.
// nil when found nowhere; *primary is then the candidate that lets the caller
// tell sandbox denial from a missing file.
//
// TRAP: against a walk's listing (knownFiles) every rung answers in the
// listing's spelling, never its own. The walk claims a sheet's files by exact
// URL while the volume folds case and Unicode normalization, and NSURL
// decomposes what it is handed: a probe that finds the listed "01 - Title.flac"
// under the sheet's "01 - title.flac" would leave it to play whole as well.
NSURL *VibeResolveEntry(NSString *entry, NSURL *dir, NSFileManager *fileManager,
                        NSMutableDictionary<NSString *, NSNumber *> *dirReachable,
                        NSDictionary<NSString *, NSArray<NSURL *> *> *knownFiles,
                        NSURL **primaryOut) {
    BOOL absolute = [entry hasPrefix:@"/"];
    NSURL *primary = absolute ? [NSURL fileURLWithPath:entry isDirectory:NO]
                              : [dir URLByAppendingPathComponent:entry isDirectory:NO];
    if (knownFiles) {
        // As the listing is spelled: "./" and "../" folded lexically, no
        // stat, no /private stripped.
        primary = primary.standardizedURL;
    }
    else if (!absolute) {
        primary = primary.URLByStandardizingPath;
    }
    // Backstop for a component the parsers' strip missed: no primary, no URL.
    if (!primary.path) {
        return nil;
    }
    *primaryOut = primary;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSURL *(^find)(NSURL *) = ^NSURL *(NSURL *url) {
        // Keyed by path, which is nil for an unpathable component; a nil
        // would raise inside the set.
        NSString *path = url.path;
        if (!path || [seen containsObject:path]) {
            return nil;
        }
        [seen addObject:path];
        return VibeKnownFileAtPath(path, knownFiles)
               ?: ([fileManager isReadableFileAtPath:path] ? url : nil);
    };
    NSURL *found = find(primary);
    if (found) {
        return found;
    }
    NSURL *beside = [dir URLByAppendingPathComponent:entry.lastPathComponent isDirectory:NO];
    found = find(beside);
    if (found) {
        return found;
    }
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
            found = find([primary.URLByDeletingPathExtension URLByAppendingPathExtension:extension]);
        }
        found = found ?: find([beside.URLByDeletingPathExtension URLByAppendingPathExtension:extension]);
        if (found) {
            return found;
        }
    }
    return nil;
}

+ (NSString *)knownFileKeyForPath:(NSString *)path {
    return path.precomposedStringWithCanonicalMapping.lowercaseString;
}

+ (NSArray<AudioTrack *> *)rowsForPlaylistAtURL:(NSURL *)url {
    if ([self isCueExtension:url.pathExtension.lowercaseString]) {
        return [self cueRowsForSheetAtURL:url knownFiles:nil];
    }
    NSString *text = VibeTextOfFile(url);
    if (!text) {
        return @[];
    }
    NSURL *dir = url.URLByDeletingLastPathComponent;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *dirReachable = [NSMutableDictionary new];
    EnumerateM3U(text, ^(NSString *entry, NSString *cue) {
        NSURL *primary = nil;
        NSURL *resolved = VibeResolveEntry(entry, dir, fileManager, dirReachable, nil, &primary) ?: primary;
        if (resolved) {
            [rows addObject:RowForEntry(resolved, cue)];
        }
    });
    return rows;
}

+ (NSArray<AudioTrack *> *)rowsInM3UData:(NSData *)data {
    NSString *text = [self textFromData:data];
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray array];
    if (!text) {
        return rows;
    }
    EnumerateM3U(text, ^(NSString *entry, NSString *cue) {
        // isDirectory:NO, or fileURLWithPath: stats the path to decide.
        NSURL *url = [entry hasPrefix:@"/"] ? [NSURL fileURLWithPath:entry isDirectory:NO] : nil;
        if (url.path) {   // nil for a component no path can hold
            [rows addObject:RowForEntry(url, cue)];
        }
    });
    return rows;
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
        [text appendFormat:@"#EXTINF:%lld,%@\n", duration > 0 ? llround(duration) : -1LL, M3UInfoName(track)];
        // A cue row: VLC's window for players that honor it, then Vibe's own
        // line, which restores the row exactly and reads nothing to do it.
        if (track.isWindowed || track.cueSheetURL) {
            if (track.cueStart > 0) {
                [text appendFormat:@"#EXTVLCOPT:start-time=%.3f\n", (double)track.cueStart / kVibeCDFramesPerSecond];
            }
            if (track.cueEnd > 0) {
                [text appendFormat:@"#EXTVLCOPT:stop-time=%.3f\n", (double)track.cueEnd / kVibeCDFramesPerSecond];
            }
            [text appendFormat:@"%@%@\n", kVibeCueDirective, CuePayload(track)];
        }
        [text appendFormat:@"%@\n", M3UPathLine(track.url.path.stringByStandardizingPath, prefix)];
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
