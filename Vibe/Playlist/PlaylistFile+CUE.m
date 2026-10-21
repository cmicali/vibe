//
//  PlaylistFile+CUE.m
//  Vibe
//

#import "PlaylistFile.h"
#import "PlaylistFileInternal.h"

#import "AudioTrack.h"
#import "PlayableExtensions.h"
#import "CueWindowMath.h"

#include <libkern/OSByteOrder.h>
#include <string.h>

@implementation PlaylistFile (CUE)

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
            NSString *name = VibeStrippedOfUnpathableCharacters(VibeNormalizePathSeparators(CueValue(rest, YES)));
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
                : knownFiles ? VibeKnownFileAtPath(path, knownFiles)
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
        // A FILE none of whose tracks survived plays whole: no audio the sheet
        // names goes missing.
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
    NSString *text = VibeTextOfFile(url);
    if (!text) {
        return @[];
    }
    NSURL *dir = url.URLByDeletingLastPathComponent;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, NSNumber *> *dirReachable = [NSMutableDictionary new];
    return [self cueRowsInText:text sheetURL:url resolvingFile:^NSURL *(NSString *name, BOOL sole) {
        NSURL *primary = nil;
        NSURL *found = name ? VibeResolveEntry(name, dir, fileManager, dirReachable, knownFiles, &primary) : nil;
        if (!found && sole) {
            found = AudioFileNamedLikeSheet(url, fileManager, knownFiles);
        }
        return found ?: primary;
    }];
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

@end
