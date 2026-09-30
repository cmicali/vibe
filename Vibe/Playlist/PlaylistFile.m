//
//  PlaylistFile.m
//  Vibe
//

#import "PlaylistFile.h"

#import "AudioTrack.h"
#import "PlayableExtensions.h"
#import "PlaybackIntent.h"

#include <libkern/OSByteOrder.h>
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
                     load:(void (^)(NSArray<AudioTrack *> *, NSUInteger, BOOL))load {
    if (!enabled) return NO;
    NSArray<AudioTrack *> *rows = [self rowsInM3UData:[NSData dataWithContentsOfURL:url]];
    if (rows.count == 0) return NO;
    NSInteger stored = [defaults integerForKey:kVibeLastPlaylistCurrentIndexKey];
    NSUInteger index = stored < 0 ? 0 : MIN((NSUInteger)stored, rows.count - 1);
    load(rows, index, YES);
    return YES;
}

+ (BOOL)isCueExtension:(NSString *)extension {
    return [extension isEqualToString:@"cue"];
}

+ (BOOL)isPlaylistExtension:(NSString *)extension {
    return [self isCueExtension:extension]
            || [extension isEqualToString:@"m3u"]
            || [extension isEqualToString:@"m3u8"];
}

// The file decoded as playlist text; nil when unreadable.
static NSString *TextOfFile(NSURL *url) {
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

// The value of a command line: quoted → between the quotes, unterminated
// quote → the rest of the line, unquoted → as written. Only FILE strips a
// trailing type keyword, and only unquoted — a quoted name is exact.
static NSString *CueValue(NSString *rest, BOOL stripFileTypeKeyword) {
    if ([rest hasPrefix:@"\""]) {
        NSRange close = [rest rangeOfString:@"\"" options:0 range:NSMakeRange(1, rest.length - 1)];
        return close.location == NSNotFound
                ? [rest substringFromIndex:1]
                : [rest substringWithRange:NSMakeRange(1, close.location - 1)];
    }
    if (!stripFileTypeKeyword) {
        return rest;
    }
    // Sloppy writers leave spaces in an unquoted name too, so take the whole
    // remainder and strip a trailing type keyword if present.
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceCharacterSet;
    NSRange lastSpace = [rest rangeOfCharacterFromSet:whitespace options:NSBackwardsSearch];
    if (lastSpace.location != NSNotFound
            && IsCueFileTypeKeyword([rest substringFromIndex:NSMaxRange(lastSpace)])) {
        return [[rest substringToIndex:lastSpace.location] stringByTrimmingCharactersInSet:whitespace];
    }
    return rest;
}

// The first whitespace-delimited token of s, which may be tab-delimited; rest
// gets the trimmed remainder.
static NSString *CueFirstToken(NSString *s, NSString *__strong *rest) {
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceCharacterSet;
    NSRange space = [s rangeOfCharacterFromSet:whitespace];
    if (space.location == NSNotFound) {
        if (rest) {
            *rest = @"";
        }
        return s;
    }
    if (rest) {
        *rest = [[s substringFromIndex:NSMaxRange(space)] stringByTrimmingCharactersInSet:whitespace];
    }
    return [s substringToIndex:space.location];
}

// MM:SS:FF as CD frames, FF being 1/75 s. MM:SS is tolerated and MM may run
// past 99. -1 for anything unparseable, so a junk INDEX is ignored rather than
// read as a zero start; out-of-range SS and FF are taken as written.
static NSInteger CueFramesFromString(NSString *text) {
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@":"];
    if (parts.count < 2 || parts.count > 3) {
        return -1;
    }
    NSInteger values[3] = {0, 0, 0};
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = parts[i];
        // integerValue saturates silently, so an absurd run of digits would
        // otherwise read as a plausible start.
        if (part.length == 0 || part.length > 6) {
            return -1;
        }
        for (NSUInteger c = 0; c < part.length; c++) {
            unichar digit = [part characterAtIndex:c];
            if (digit < '0' || digit > '9') {
                return -1;
            }
        }
        values[i] = part.integerValue;
    }
    return (values[0] * 60 + values[1]) * (NSInteger)kVibeCDFramesPerSecond + values[2];
}

// A sheet's AUDIO tracks, kept by the drop rules, each as {file, number,
// title, performer, start}: file indexes files, -1 for a track before any FILE
// line. A track belongs to the FILE its start INDEX sits in — EAC's
// one-file-per-track layout puts a track's INDEX 00 at the end of the previous
// file and its INDEX 01 at the start of its own.
static NSArray<NSDictionary *> *CueTracksInText(NSString *text, NSMutableArray<NSString *> *files,
                                                NSString *__strong *sheetPerformer) {
    NSMutableArray<NSDictionary *> *tracks = [NSMutableArray new];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceCharacterSet;
    // nil inside a non-AUDIO TRACK, so its TITLE, PERFORMER and INDEX land
    // nowhere rather than leaking onto the previous track or the sheet.
    __block NSMutableDictionary *current = nil;
    __block BOOL seenTrack = NO;
    __block NSString *performer = nil;
    __block NSInteger index00 = -1, index01 = -1, file00 = -1, file01 = -1;
    // The drop rules below measure against the last kept start in the same
    // file — tracks arrive in file order, since files only grow — so one
    // broken track cannot take the rest with it.
    __block NSInteger keptFile = NSIntegerMin, keptStart = -1;
    void (^finish)(void) = ^{
        if (!current) {
            return;
        }
        // INDEX 01 beats INDEX 00; neither drops the track, and so does a
        // start below the file's last kept one: a marker list must be ordered.
        NSInteger start = index01 >= 0 ? index01 : index00;
        NSInteger file = index01 >= 0 ? file01 : file00;
        if (start < 0 || (file == keptFile && start < keptStart)) {
            return;
        }
        keptFile = file;
        keptStart = start;
        current[@"start"] = @(start);
        current[@"file"] = @(file);
        [tracks addObject:current];
    };
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:whitespace];
        if (trimmed.length == 0) {
            return;
        }
        NSString *rest = nil;
        NSString *keyword = CueFirstToken(trimmed, &rest).uppercaseString;
        if ([keyword isEqualToString:@"FILE"]) {
            NSString *name = StrippedOfUnpathableCharacters(NormalizePathSeparators(CueValue(rest, YES)));
            // Some writers repeat the one image's FILE before every TRACK.
            if (name.length > 0
                    && (files.count == 0 || [files.lastObject caseInsensitiveCompare:name] != NSOrderedSame)) {
                [files addObject:name];
            }
        }
        else if ([keyword isEqualToString:@"TRACK"]) {
            finish();
            current = nil;
            index00 = index01 = -1;
            seenTrack = YES;
            NSString *afterNumber = nil;
            NSString *number = CueFirstToken(rest, &afterNumber);
            if ([CueFirstToken(afterNumber, NULL) caseInsensitiveCompare:@"AUDIO"] != NSOrderedSame) {
                return;
            }
            current = [NSMutableDictionary dictionaryWithObject:@(number.integerValue) forKey:@"number"];
        }
        else if ([keyword isEqualToString:@"TITLE"] || [keyword isEqualToString:@"PERFORMER"]) {
            NSString *value = CueValue(rest, NO);
            if (value.length == 0) {
                return;
            }
            BOOL isTitle = [keyword isEqualToString:@"TITLE"];
            if (!seenTrack) {
                // The sheet's TITLE names the album, which Vibe shows for no file.
                if (!isTitle) {
                    performer = value;
                }
            }
            else {
                current[isTitle ? @"title" : @"performer"] = value;
            }
        }
        else if ([keyword isEqualToString:@"INDEX"] && current) {
            NSString *afterNumber = nil;
            NSInteger number = CueFirstToken(rest, &afterNumber).integerValue;
            NSInteger frames = CueFramesFromString(CueFirstToken(afterNumber, NULL));
            if (frames < 0) {
                return;
            }
            if (number == 1) {
                index01 = frames;
                file01 = (NSInteger)files.count - 1;
            }
            else if (number == 0) {
                index00 = frames;
                file00 = (NSInteger)files.count - 1;
            }
        }
        // REM, FLAGS, ISRC, CATALOG, SONGWRITER, PREGAP, POSTGAP and junk are
        // ignored. REM TITLE "…" falls out for free: REM is the keyword.
    }];
    finish();
    if (sheetPerformer) {
        *sheetPerformer = performer;
    }
    return tracks;
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
        entry = StrippedOfUnpathableCharacters(NormalizePathSeparators(entry));
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

static NSURL *KnownFileAtPath(NSString *path, NSDictionary<NSString *, NSArray<NSURL *> *> *knownFiles) {
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

// The audio named like the sheet beside it — Mix.cue's Mix.flac — lossless
// first; nil when none is readable. The last rung for a sheet whose one image
// is named nowhere findable (a long-gone CDImage.wav) or not named at all. A
// walk's listing, when given, answers for the sheet's own folder unprobed.
static NSURL *AudioFileNamedLikeSheet(NSURL *sheet, NSFileManager *fileManager,
                                      NSDictionary<NSString *, NSArray<NSURL *> *> *knownFiles) {
    NSURL *base = sheet.URLByDeletingPathExtension;
    for (NSString *extension in PlayableExtensions.ordered) {
        NSURL *candidate = [base URLByAppendingPathExtension:extension];
        NSString *path = candidate.path;
        NSURL *found = !path ? nil
                : knownFiles ? KnownFileAtPath(path, knownFiles)
                : ([fileManager isReadableFileAtPath:path] ? candidate : nil);
        if (found) {
            return found;
        }
    }
    return nil;
}

+ (NSArray<AudioTrack *> *)cueRowsInText:(NSString *)text sheetURL:(NSURL *)sheetURL
                           resolvingFile:(NSURL *(^)(NSString *name, BOOL sole))resolve {
    NSMutableArray<NSString *> *files = [NSMutableArray new];
    NSString *sheetPerformer = nil;
    NSArray<NSDictionary *> *tracks = CueTracksInText(text, files, &sheetPerformer);
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray arrayWithCapacity:MAX(tracks.count, files.count)];
    // Tracks arrive in file order, so each FILE's are one run; a track before
    // any FILE line (-1) comes first. Each file is resolved once, in order.
    NSUInteger next = 0;
    NSInteger first = tracks.count > 0 && [tracks[0][@"file"] integerValue] < 0 ? -1 : 0;
    for (NSInteger file = first; file < (NSInteger)files.count; file++) {
        NSUInteger begin = next;
        while (next < tracks.count && [tracks[next][@"file"] integerValue] == file) {
            next++;
        }
        NSURL *url = resolve(file >= 0 ? files[(NSUInteger)file] : nil, files.count <= 1);
        if (!url) {
            continue;
        }
        // A FILE none of whose tracks survived plays whole, as every FILE did
        // before sheets had rows: no audio the sheet names goes missing.
        if (next == begin) {
            [rows addObject:[AudioTrack withURL:url]];
            continue;
        }
        for (NSUInteger i = begin; i < next; i++) {
            // A file's audio before its first INDEX 01 — a pregap, or hidden
            // audio before track 1 — belongs to its first row, so none is
            // unreachable. A row runs to the next of its file, so a pregap plays
            // at the end of the row before it, as on a CD; the last runs to the
            // file's end.
            NSUInteger start = i == begin ? 0 : [tracks[i][@"start"] unsignedIntegerValue];
            BOOL hasNext = i + 1 < next;
            NSUInteger end = hasNext ? [tracks[i + 1][@"start"] unsignedIntegerValue] : 0;
            // An end of 0 means the file's end, so an empty window — the next
            // row starting where this one does, 0 included — is dropped here.
            if (hasNext && end <= start) {
                continue;
            }
            [rows addObject:[[AudioTrack alloc] initWithURL:url cueStart:start cueEnd:end
                                                      title:tracks[i][@"title"]
                                                  performer:tracks[i][@"performer"] ?: sheetPerformer
                                                      sheet:sheetURL
                                                trackNumber:[tracks[i][@"number"] integerValue]]];
        }
    }
    return rows;
}

+ (NSArray<AudioTrack *> *)cueRowsForSheetAtURL:(NSURL *)url
                                     knownFiles:(NSDictionary<NSString *, NSArray<NSURL *> *> *)knownFiles {
    NSString *text = TextOfFile(url);
    if (!text) {
        return @[];
    }
    NSURL *dir = url.URLByDeletingLastPathComponent;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, NSNumber *> *dirReachable = [NSMutableDictionary new];
    return [self cueRowsInText:text sheetURL:url resolvingFile:^NSURL *(NSString *name, BOOL sole) {
        NSURL *resolved = nil;
        if (name && knownFiles) {
            NSString *path = [name hasPrefix:@"/"] ? name : [dir.path stringByAppendingPathComponent:name];
            // Lexically, as the listing is spelled: "./" and "../" folded, no
            // stat, no /private stripped.
            path = [NSURL fileURLWithPath:path isDirectory:NO].standardizedURL.path;
            resolved = KnownFileAtPath(path, knownFiles);
        }
        if (!resolved) {
            resolved = name ? ResolveEntry(name, dir, fileManager, dirReachable) : nil;
            if (sole && !(resolved && [fileManager isReadableFileAtPath:resolved.path])) {
                resolved = AudioFileNamedLikeSheet(url, fileManager, knownFiles) ?: resolved;
            }
        }
        return resolved;
    }];
}

+ (NSString *)knownFileKeyForPath:(NSString *)path {
    return path.precomposedStringWithCanonicalMapping.lowercaseString;
}

#pragma mark - A FLAC's own sheet

// The CUESHEET Vorbis comment (foobar2000's embedding): a whole sheet as text.
static NSString *CueSheetCommentInBlock(NSData *block) {
    const uint8_t *bytes = block.bytes;
    NSUInteger length = block.length;
    if (length < 8) {
        return nil;
    }
    uint64_t p = 4 + (uint64_t)OSReadLittleInt32(bytes, 0);
    if (p + 4 > length) {
        return nil;
    }
    uint32_t count = OSReadLittleInt32(bytes, p);
    p += 4;
    for (uint32_t i = 0; i < count && p + 4 <= length; i++) {
        uint64_t size = OSReadLittleInt32(bytes, p);
        p += 4;
        if (p + size > length) {
            return nil;
        }
        if (size > 9 && strncasecmp((const char *)bytes + p, "CUESHEET=", 9) == 0) {
            return [PlaylistFile textFromData:[block subdataWithRange:NSMakeRange((NSUInteger)p + 9, (NSUInteger)size - 9)]];
        }
        p += size;
    }
    return nil;
}

// The binary CUESHEET block (flac --cuesheet, EAC) as the sheet text it was
// made from, so one parser decides every row. Offsets are samples, rounded to
// CD frames: exact for a CD rip, whose offsets fall on 588-sample frames, and
// within 1/150 s at any other rate. Non-audio tracks and the lead-out drop.
static NSString *CueTextForBlock(NSData *block, uint32_t rate) {
    const uint8_t *bytes = block.bytes;
    NSUInteger length = block.length;
    // Catalog number, lead-in, the CD flag and reserved bytes, then the count.
    const NSUInteger tracksAt = 128 + 8 + 259;
    if (rate == 0 || length <= tracksAt) {
        return nil;
    }
    NSMutableString *text = [NSMutableString stringWithString:@"FILE \"\" WAVE\n"];
    NSUInteger count = bytes[tracksAt];
    NSUInteger p = tracksAt + 1;
    for (NSUInteger t = 0; t < count && p + 36 <= length; t++) {
        uint64_t offset = OSReadBigInt64(bytes, p);
        uint8_t number = bytes[p + 8];
        BOOL audio = !(bytes[p + 21] & 0x80);
        NSUInteger indexes = bytes[p + 35];
        p += 36;
        if (number == 170 || number == 255) {
            break;
        }
        if (audio) {
            [text appendFormat:@"TRACK %u AUDIO\n", (unsigned)number];
        }
        for (NSUInteger i = 0; i < indexes && p + 12 <= length; i++, p += 12) {
            if (audio) {
                long long perSecond = kVibeCDFramesPerSecond;
                long long frames = llround((double)(offset + OSReadBigInt64(bytes, p)) * perSecond / rate);
                [text appendFormat:@"INDEX %02u %lld:%02lld:%02lld\n", (unsigned)bytes[p + 8],
                        frames / (60 * perSecond), frames / perSecond % 60, frames % perSecond];
            }
        }
    }
    return text;
}

// The metadata blocks alone: a leading ID3v2 tag some writers add is skipped,
// a picture is seeked over, and no audio frame is read.
static void ReadFLACCueSources(FILE *file, uint32_t *rate, NSString **text, NSData **block) {
    uint8_t head[10];
    if (fread(head, 1, sizeof head, file) != sizeof head) {
        return;
    }
    off_t start = 0;
    if (memcmp(head, "ID3", 3) == 0) {
        start = 10 + ((off_t)(head[6] & 0x7f) << 21 | (head[7] & 0x7f) << 14 | (head[8] & 0x7f) << 7 | (head[9] & 0x7f));
        start += (head[5] & 0x10) ? 10 : 0;   // the footer
    }
    uint8_t magic[4];
    if (fseeko(file, start, SEEK_SET) != 0 || fread(magic, 1, 4, file) != 4 || memcmp(magic, "fLaC", 4) != 0) {
        return;
    }
    // Bounded, so a corrupt chain cannot spin.
    for (int blocks = 0; blocks < 256; blocks++) {
        uint8_t header[4];
        if (fread(header, 1, 4, file) != 4) {
            return;
        }
        uint8_t type = header[0] & 0x7f;
        size_t length = (size_t)header[1] << 16 | (size_t)header[2] << 8 | header[3];
        if (type == 0 || type == 4 || type == 5) {
            NSMutableData *data = [NSMutableData dataWithLength:length];
            if (fread(data.mutableBytes, 1, length, file) != length) {
                return;
            }
            const uint8_t *bytes = data.bytes;
            if (type == 0 && length >= 13) {
                *rate = (uint32_t)bytes[10] << 12 | (uint32_t)bytes[11] << 4 | bytes[12] >> 4;
            }
            else if (type == 4) {
                *text = CueSheetCommentInBlock(data);
            }
            else if (type == 5) {
                *block = data;
            }
        }
        else if (fseeko(file, (off_t)length, SEEK_CUR) != 0) {
            return;
        }
        if (header[0] & 0x80) {
            return;
        }
    }
}

+ (NSArray<AudioTrack *> *)cueRowsEmbeddedInFLACAtURL:(NSURL *)url {
    FILE *file = fopen(url.fileSystemRepresentation, "rb");
    if (!file) {
        return @[];
    }
    uint32_t rate = 0;
    NSString *text = nil;
    NSData *block = nil;
    ReadFLACCueSources(file, &rate, &text, &block);
    fclose(file);
    // The text carries titles, the block only marks.
    for (NSString *sheet in @[text ?: @"", CueTextForBlock(block, rate) ?: @""]) {
        // The sheet's FILE names what was ripped; the audio is this file. The
        // first FILE only, since a second would lay its windows over the same
        // audio.
        __block BOOL resolved = NO;
        NSArray<AudioTrack *> *rows = [self cueRowsInText:sheet sheetURL:url
                                            resolvingFile:^NSURL *(NSString *name, BOOL sole) {
            BOOL first = !resolved;
            resolved = YES;
            return first ? url : nil;
        }];
        if (rows.count > 1) {
            return rows;
        }
    }
    return @[];
}

+ (NSArray<AudioTrack *> *)rowsForPlaylistAtURL:(NSURL *)url {
    if ([self isCueExtension:url.pathExtension.lowercaseString]) {
        return [self cueRowsForSheetAtURL:url knownFiles:nil];
    }
    NSString *text = TextOfFile(url);
    if (!text) {
        return @[];
    }
    NSURL *dir = url.URLByDeletingLastPathComponent;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *dirReachable = [NSMutableDictionary new];
    EnumerateM3U(text, ^(NSString *entry, NSString *cue) {
        NSURL *resolved = ResolveEntry(entry, dir, fileManager, dirReachable);
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
