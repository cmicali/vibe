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
                     load:(void (^)(NSArray<AudioTrack *> *, NSUInteger, BOOL))load {
    if (!enabled) return NO;
    NSArray<AudioTrack *> *rows = [self rowsInM3UData:[NSData dataWithContentsOfURL:url]];
    if (rows.count == 0) return NO;
    NSInteger stored = [defaults integerForKey:kVibeLastPlaylistCurrentIndexKey];
    NSUInteger index = stored < 0 ? 0 : MIN((NSUInteger)stored, rows.count - 1);
    load(rows, index, YES);
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
    return (values[0] * 60 + values[1]) * 75 + values[2];
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
    // file, so one broken track cannot take the rest with it.
    NSMutableDictionary<NSNumber *, NSNumber *> *lastKeptStart = [NSMutableDictionary new];
    void (^finish)(void) = ^{
        if (!current) {
            return;
        }
        // INDEX 01 beats INDEX 00; neither drops the track, and so does a
        // start below the file's last kept one: a marker list must be ordered.
        NSInteger start = index01 >= 0 ? index01 : index00;
        NSInteger file = index01 >= 0 ? file01 : file00;
        if (start < 0 || start < [lastKeptStart[@(file)] integerValue]) {
            return;
        }
        lastKeptStart[@(file)] = @(start);
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

// The audio named like the sheet beside it — Mix.cue's Mix.flac — lossless
// first; nil when none is readable. The last rung for a sheet whose one image
// is named nowhere findable (a long-gone CDImage.wav) or not named at all.
static NSURL *AudioFileNamedLikeSheet(NSURL *sheet, NSFileManager *fileManager) {
    NSURL *base = sheet.URLByDeletingPathExtension;
    for (NSString *extension in PlayableExtensions.ordered) {
        NSURL *candidate = [base URLByAppendingPathExtension:extension];
        if (candidate.path && [fileManager isReadableFileAtPath:candidate.path]) {
            return candidate;
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
    // Resolved once per FILE, whichever of its tracks asks first.
    NSMutableDictionary<NSNumber *, id> *urls = [NSMutableDictionary new];
    NSURL *(^urlForFile)(NSInteger) = ^NSURL *(NSInteger file) {
        id url = urls[@(file)];
        if (!url) {
            url = resolve(file >= 0 ? files[(NSUInteger)file] : nil, files.count <= 1) ?: NSNull.null;
            urls[@(file)] = url;
        }
        return url == NSNull.null ? nil : url;
    };
    // Sheet order: files only grow, and a track before any FILE line (-1)
    // comes first.
    NSMutableDictionary<NSNumber *, NSMutableArray<NSDictionary *> *> *tracksByFile = [NSMutableDictionary new];
    for (NSDictionary *track in tracks) {
        NSMutableArray<NSDictionary *> *own = tracksByFile[track[@"file"]];
        if (!own) {
            own = [NSMutableArray new];
            tracksByFile[track[@"file"]] = own;
        }
        [own addObject:track];
    }
    NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:files.count + 1];
    if (tracksByFile[@(-1)]) {
        [order addObject:@(-1)];
    }
    for (NSUInteger file = 0; file < files.count; file++) {
        [order addObject:@(file)];
    }
    for (NSNumber *file in order) {
        NSArray<NSDictionary *> *own = tracksByFile[file];
        NSUInteger rowsBefore = rows.count;
        for (NSUInteger i = 0; i < own.count; i++) {
            // A file's audio before its first INDEX 01 — a pregap, or hidden
            // audio before track 1 — belongs to its first row, so none is
            // unreachable. A row runs to the next of its file, so a pregap plays
            // at the end of the row before it, as on a CD; the last runs to the
            // file's end.
            NSUInteger start = i == 0 ? 0 : [own[i][@"start"] unsignedIntegerValue];
            BOOL hasNext = i + 1 < own.count;
            NSUInteger end = hasNext ? [own[i + 1][@"start"] unsignedIntegerValue] : 0;
            // An end of 0 means the file's end, so an empty window — the next
            // row starting where this one does, 0 included — is dropped here.
            if (hasNext && end <= start) {
                continue;
            }
            NSURL *url = urlForFile(file.integerValue);
            if (!url) {
                break;
            }
            [rows addObject:[[AudioTrack alloc] initWithURL:url cueStart:start cueEnd:end
                                                      title:own[i][@"title"]
                                                  performer:own[i][@"performer"] ?: sheetPerformer
                                                      sheet:sheetURL
                                                trackNumber:[own[i][@"number"] integerValue]]];
        }
        // A FILE none of whose tracks survived plays whole, as every FILE did
        // before sheets had rows: no audio the sheet names goes missing.
        if (rows.count == rowsBefore && file.integerValue >= 0) {
            NSURL *url = urlForFile(file.integerValue);
            if (url) {
                [rows addObject:[AudioTrack withURL:url]];
            }
        }
    }
    return rows;
}

+ (NSArray<AudioTrack *> *)cueRowsForSheetAtURL:(NSURL *)url
                                     knownFiles:(NSDictionary<NSString *, NSURL *> *)knownFiles {
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSString *text = data ? [self textFromData:data] : nil;
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
            resolved = path ? knownFiles[[self knownFileKeyForPath:path]] : nil;
        }
        if (!resolved) {
            resolved = name ? ResolveEntry(name, dir, fileManager, dirReachable) : nil;
            if (sole && !(resolved && [fileManager isReadableFileAtPath:resolved.path])) {
                resolved = AudioFileNamedLikeSheet(url, fileManager) ?: resolved;
            }
        }
        return resolved;
    }];
}

+ (NSArray<AudioTrack *> *)cueRowsForSheetAtURL:(NSURL *)url {
    return [self cueRowsForSheetAtURL:url knownFiles:nil];
}

+ (NSString *)knownFileKeyForPath:(NSString *)path {
    return path.precomposedStringWithCanonicalMapping.lowercaseString;
}

+ (NSArray<AudioTrack *> *)rowsForPlaylistAtURL:(NSURL *)url {
    if ([url.pathExtension.lowercaseString isEqualToString:@"cue"]) {
        return [self cueRowsForSheetAtURL:url];
    }
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSString *text = data ? [self textFromData:data] : nil;
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
                [text appendFormat:@"#EXTVLCOPT:start-time=%.3f\n", track.cueStart / 75.0];
            }
            if (track.cueEnd > 0) {
                [text appendFormat:@"#EXTVLCOPT:stop-time=%.3f\n", track.cueEnd / 75.0];
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
