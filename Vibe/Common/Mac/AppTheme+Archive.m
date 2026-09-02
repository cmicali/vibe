//
//  AppTheme+Archive.m
//  Vibe
//

#import "AppTheme+Archive.h"
#import "AppThemeInternal.h"
#import <compression.h>

// Minimal ZIP, self-contained: the writer emits stored (uncompressed)
// entries; the reader takes stored and raw-deflate ones, which covers both
// our own exports and a zip a person made by hand (Finder compresses).

static uint32_t VibeCRC32(NSData *data) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) {
                c = (c & 1) ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            }
            table[i] = c;
        }
    });
    uint32_t crc = 0xFFFFFFFF;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        crc = table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

// The ZIP's DOS date/time as one packed word, date in the high half: seconds/2,
// minute and hour below; day, month and year-1980 above. Zero is a legal field
// but extracts as 1979-11-29, so entries carry the export's own wall time. The
// 7-bit year cannot hold a clock outside 1980-2107, so a bogus one clamps
// rather than wrapping into a stranger date than it started with.
static uint32_t VibeDOSTimestampNow(void) {
    NSDateComponents *now = [NSCalendar.currentCalendar
            components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                       NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond
              fromDate:NSDate.date];
    NSInteger year = clampRange(now.year, 1980, 2107);
    uint32_t time = (uint32_t)(now.second / 2) |
                    ((uint32_t)now.minute << 5) | ((uint32_t)now.hour << 11);
    uint32_t date = (uint32_t)now.day |
                    ((uint32_t)now.month << 5) | ((uint32_t)(year - 1980) << 9);
    return (date << 16) | time;
}

static void VibeAppendLE(NSMutableData *out, uint64_t value, int bytes) {
    for (int i = 0; i < bytes; i++) {
        uint8_t byte = (value >> (8 * i)) & 0xFF;
        [out appendBytes:&byte length:1];
    }
}

static NSData *VibeZipData(NSDictionary<NSString *, NSData *> *entries) {
    NSMutableData *out = [NSMutableData data];
    NSMutableData *central = [NSMutableData data];
    // One stamp for every entry: the archive is written in a single pass, so a
    // per-entry read would only differ when the write straddles a second.
    uint32_t stamp = VibeDOSTimestampNow();
    NSUInteger count = 0;
    for (NSString *name in [entries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *data = entries[name];
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = VibeCRC32(data);
        NSUInteger offset = out.length;
        VibeAppendLE(out, 0x04034b50, 4);
        VibeAppendLE(out, 20, 2);              // version needed
        VibeAppendLE(out, 0, 2);               // flags
        VibeAppendLE(out, 0, 2);               // method: stored
        VibeAppendLE(out, stamp, 4);           // dos time/date
        VibeAppendLE(out, crc, 4);
        VibeAppendLE(out, data.length, 4);     // compressed
        VibeAppendLE(out, data.length, 4);     // uncompressed
        VibeAppendLE(out, nameData.length, 2);
        VibeAppendLE(out, 0, 2);               // extra
        [out appendData:nameData];
        [out appendData:data];

        VibeAppendLE(central, 0x02014b50, 4);
        VibeAppendLE(central, 20, 2);          // made by
        VibeAppendLE(central, 20, 2);          // needed
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, stamp, 4);       // must match the local header's
        VibeAppendLE(central, crc, 4);
        VibeAppendLE(central, data.length, 4);
        VibeAppendLE(central, data.length, 4);
        VibeAppendLE(central, nameData.length, 2);
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 4);
        VibeAppendLE(central, offset, 4);
        [central appendData:nameData];
        count++;
    }
    NSUInteger centralOffset = out.length;
    [out appendData:central];
    VibeAppendLE(out, 0x06054b50, 4);
    VibeAppendLE(out, 0, 2);
    VibeAppendLE(out, 0, 2);
    VibeAppendLE(out, count, 2);
    VibeAppendLE(out, count, 2);
    VibeAppendLE(out, central.length, 4);
    VibeAppendLE(out, centralOffset, 4);
    VibeAppendLE(out, 0, 2);
    return out;
}

static uint32_t VibeReadLE(const uint8_t *bytes, int width) {
    uint32_t value = 0;
    for (int i = width - 1; i >= 0; i--) {
        value = (value << 8) | bytes[i];
    }
    return value;
}

// The whole theme archive's ceiling — one JSON plus one image, with slack.
// Both the pre-parse input gate and the unzip's running inflate budget use it.
static const NSUInteger kThemeArchiveByteCap = 2 * 8 * 1024 * 1024 + 64 * 1024;
// A theme archive is one JSON plus at most two images; a Finder zip adds its
// __MACOSX sidecars. The count is a 16-bit field, and walking 65,535 headers
// to reject them one by one is itself the attack.
static const NSUInteger kThemeArchiveEntryCap = 64;

// nil when the data is not a zip this reader can walk. Entries it cannot
// decode (an unsupported method) are skipped rather than fatal.
static NSDictionary<NSString *, NSData *> *VibeUnzipData(NSData *zip) {
    const uint8_t *bytes = zip.bytes;
    NSUInteger length = zip.length;
    if (length < 22) {
        return nil;
    }
    // Find the end-of-central-directory record from the tail (comment ≤ 64KB).
    NSInteger eocd = -1;
    NSInteger floor = MAX(0, (NSInteger)length - 22 - 65535);
    for (NSInteger i = (NSInteger)length - 22; i >= floor; i--) {
        if (VibeReadLE(bytes + i, 4) == 0x06054b50) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        return nil;
    }
    NSUInteger count = VibeReadLE(bytes + eocd + 10, 2);
    NSUInteger offset = VibeReadLE(bytes + eocd + 16, 4);
    if (count > kThemeArchiveEntryCap) {
        return nil;
    }
    // A total budget across all entries, so deflate's ~1000:1 ratio cannot
    // aim thousands of central-directory entries at one small stream and
    // exhaust memory. One JSON plus one image is all the caller needs.
    NSUInteger budget = kThemeArchiveByteCap;
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++) {
        // Per entry, because everything below it is transient but the name and
        // the accepted payload: a rejected entry must not hold its bytes until
        // the whole walk returns.
        @autoreleasepool {
            if (offset + 46 > length || VibeReadLE(bytes + offset, 4) != 0x02014b50) {
                return nil;
            }
            NSUInteger method = VibeReadLE(bytes + offset + 10, 2);
            NSUInteger csize = VibeReadLE(bytes + offset + 20, 4);
            NSUInteger usize = VibeReadLE(bytes + offset + 24, 4);
            NSUInteger nameLength = VibeReadLE(bytes + offset + 28, 2);
            NSUInteger extraLength = VibeReadLE(bytes + offset + 30, 2);
            NSUInteger commentLength = VibeReadLE(bytes + offset + 32, 2);
            NSUInteger local = VibeReadLE(bytes + offset + 42, 4);
            // TRAP: the fixed 46-byte header is bounds-checked above, but the
            // variable-length name that follows is NOT — a crafted nameLength
            // (≤65535) would read past the buffer. Guard the name AND the offset
            // advance before touching either.
            if (offset + 46 + nameLength + extraLength + commentLength > length) {
                return nil;
            }
            NSString *name = [[NSString alloc] initWithBytes:bytes + offset + 46
                    length:nameLength encoding:NSUTF8StringEncoding];
            offset += 46 + nameLength + extraLength + commentLength;
            if (local + 30 > length || VibeReadLE(bytes + local, 4) != 0x04034b50) {
                return nil;
            }
            NSUInteger localName = VibeReadLE(bytes + local + 26, 2);
            NSUInteger localExtra = VibeReadLE(bytes + local + 28, 2);
            NSUInteger dataStart = local + 30 + localName + localExtra;
            if (dataStart + csize > length || !name || [name hasSuffix:@"/"]) {
                continue;
            }
            // TRAP: charge the budget from the HEADER's sizes, BEFORE any bytes
            // are materialized. Copying first and charging after is what the
            // budget cannot save you from: every header in a small archive can
            // point at the same large stream, so the copies exhaust memory
            // while each one still measures under the remaining budget.
            if (method == 0 && csize <= budget) {
                budget -= csize;
                entries[name] = [zip subdataWithRange:NSMakeRange(dataStart, csize)];
            } else if (method == 8 && usize > 0 && usize <= budget) {
                NSMutableData *inflated = [NSMutableData dataWithLength:usize];
                // Inflated straight out of the caller's buffer: the compressed
                // bytes need no copy of their own to be read.
                size_t written = compression_decode_buffer(inflated.mutableBytes, usize,
                        bytes + dataStart, csize, NULL, COMPRESSION_ZLIB);
                if (written == usize) {
                    budget -= usize;
                    entries[name] = inflated;
                }
            }
        }
    }
    return entries;
}

@implementation AppTheme (Archive)

+ (NSData *)archiveDataForRecord:(NSDictionary<NSString *, id> *)record
                            name:(NSString *)name {
    // Entries are named by SLOT, not by where the image came from: a built-in
    // names its image by a bundled filename and a user theme by a content
    // hash, and neither reads as anything to a person opening the ZIP. Both
    // sides ride along — the dormant light half of a single-mode theme
    // included, so a mode flip after re-import still round-trips.
    NSDictionary<NSString *, NSString *> *slotNames = @{
        kFieldDefaultArtworkDark:  @"artwork_default_front",
        kFieldDefaultArtworkLight: @"artwork_default_back",
    };
    NSDictionary<NSString *, id> *fields = [self sanitizedRecord:record];
    NSMutableDictionary<NSString *, NSData *> *entries = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *nameForValue = [NSMutableDictionary dictionary];
    for (NSString *key in @[kFieldDefaultArtworkDark, kFieldDefaultArtworkLight]) {
        NSString *art = fields[key];
        // Both sides naming ONE image share its entry rather than shipping the
        // bytes twice — the common single-mode and both-sides-alike cases.
        if (nameForValue[art]) {
            names[key] = nameForValue[art];
            continue;
        }
        // A built-in's art ships in THIS build, so the export could name it
        // and stop. It travels anyway: the archive is the portable form, and
        // the build that opens it may not be this one.
        NSData *image = [self dataForDefaultArtwork:art];
        if (!image) {
            continue;
        }
        NSString *entry = [slotNames[key] stringByAppendingPathExtension:art.pathExtension];
        entries[entry] = image;
        names[key] = entry;
        nameForValue[art] = entry;
    }
    if (!entries.count) {
        return nil;
    }
    entries[@"theme.json"] = [self JSONDataForRecord:record name:name artworkNames:names];
    return VibeZipData(entries);
}

+ (NSDictionary<NSString *, id> *)recordFromJSONOrArchiveData:(NSData *)data
                                                         name:(NSString **)outName
                                                        error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    BOOL isZip = data.length > 4 && bytes[0] == 'P' && bytes[1] == 'K';
    if (!isZip) {
        NSMutableDictionary *record =
                [[self recordFromJSONData:data name:outName error:error] mutableCopy];
        // JSON alone cannot carry the images: a custom reference that names
        // nothing already stored here is dangling — drop it, keep the theme.
        for (NSString *key in @[kFieldDefaultArtworkDark, kFieldDefaultArtworkLight]) {
            NSString *art = record[key];
            if ([art hasPrefix:@"custom:"] && [self defaultArtworkIsMissing:art]) {
                [record removeObjectForKey:key];
            }
        }
        return record;
    }
    if (data.length > kThemeArchiveByteCap) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:1 userInfo:nil];
        }
        return nil;
    }
    NSDictionary<NSString *, NSData *> *entries = VibeUnzipData(data);
    // Skip a Finder zip's AppleDouble sidecars — __MACOSX/._theme.json has a
    // .json extension but is not JSON, and would nondeterministically win.
    NSMutableDictionary<NSString *, NSData *> *byBaseName = [NSMutableDictionary dictionary];
    // Walked sorted, first name winning, so an archive holding two entries
    // that share a base name resolves the same way every time — NSDictionary
    // enumeration order is arbitrary.
    for (NSString *entry in [entries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *base = entry.lastPathComponent;
        if ([entry hasPrefix:@"__MACOSX/"] || [base hasPrefix:@"._"] || byBaseName[base]) {
            continue;
        }
        byBaseName[base] = entries[entry];
    }
    // theme.json is the name every export writes, so it wins outright; a
    // hand-assembled archive naming its theme something else takes the first
    // JSON in that same sorted order.
    NSData *json = byBaseName[@"theme.json"];
    for (NSString *base in [byBaseName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (!json && [base.pathExtension isEqualToString:@"json"]) {
            json = byBaseName[base];
        }
    }
    if (!json) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:5 userInfo:
                    @{NSLocalizedDescriptionKey: @"the archive carries no theme JSON"}];
        }
        return nil;
    }
    NSMutableDictionary *record =
            [[self recordFromJSONData:json name:outName error:error] mutableCopy];
    if (!record) {
        return nil;
    }
    // Inside an archive an image reference is the bare name of the entry
    // beside the JSON ("" is still the factory image). A custom: or bundled:
    // prefix is tolerated — a hand-edited file — and means nothing extra
    // here, since the entry is what the reference resolves against either
    // way: whatever precedes a colon is dropped. Read from the RAW JSON,
    // because the sanitizer admits only the two prefixed shapes and has
    // already dropped a bare name from the record.
    NSDictionary<NSString *, NSString *> *references =
            [self rawDefaultArtworkReferencesInJSONData:json];
    for (NSString *key in @[kFieldDefaultArtworkDark, kFieldDefaultArtworkLight]) {
        NSString *art = references[key];
        if (!art) {
            continue;
        }
        NSString *entry = [art componentsSeparatedByString:@":"].lastObject;
        // Re-validated and re-hashed from the bytes, never trusting the name:
        // the stored custom:<sha1> form is the only shape the sanitizer admits
        // for a container image, and it is where EVERY archived image lands —
        // a built-in's included, since a slot-named entry says nothing about
        // which build's Resources the bytes started in.
        // An image that fails validation costs its field and nothing else —
        // the theme still imports — so its reason never lands in the caller's
        // error beside a record.
        NSData *image = byBaseName[entry];
        NSString *stored = image ? [self storeCustomArtworkData:image error:NULL] : nil;
        if (stored) {
            record[key] = stored;
        } else {
            [record removeObjectForKey:key];
        }
    }
    return record;
}

@end
