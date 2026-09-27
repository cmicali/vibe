//
//  AppTheme+Archive.m
//  Vibe
//

#import "AppTheme+Archive.h"
#import "AppThemeInternal.h"
#import <compression.h>

// Minimal ZIP: the writer emits stored entries; the reader also takes
// raw-deflate, which Finder writes.

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

// DOS date (high half) and time. Zero would extract as 1979-11-29, so entries
// carry the wall time; the 7-bit year clamps to 1980-2107 rather than wrap.
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

// One JSON plus one image per image field at the byte cap, with slack: the
// input gate and the unzip's running budget.
static NSUInteger VibeThemeArchiveByteCap(void) {
    return AppTheme.imageFieldKeys.count * kVibeThemeImageByteCap + 64 * 1024;
}
// Room for a Finder zip's __MACOSX sidecars. Walking 65,535 headers to reject
// them one by one would itself be the attack.
static const NSUInteger kThemeArchiveEntryCap = 64;

// nil when the data is not a walkable zip; an undecodable entry is skipped.
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
    // One budget across all entries, so deflate's ~1000:1 ratio cannot aim
    // many entries at one small stream and exhaust memory.
    NSUInteger budget = VibeThemeArchiveByteCap();
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++) {
        // Per entry, so a rejected entry's bytes do not live until the walk
        // returns.
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
            // TRAP: the 46-byte check does not cover the variable-length name,
            // extra and comment after it; a crafted length reads past the
            // buffer. Guard them before reading the name or advancing offset.
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
            // TRAP: test the budget against the HEADER's sizes before
            // materializing any bytes. Every header can point at the same
            // large stream, so copies that each fit the remaining budget would
            // together exhaust memory.
            if (method == 0 && csize <= budget) {
                budget -= csize;
                entries[name] = [zip subdataWithRange:NSMakeRange(dataStart, csize)];
            } else if (method == 8 && usize > 0 && usize <= budget) {
                NSMutableData *inflated = [NSMutableData dataWithLength:usize];
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
    // Every image field rides along, a single-mode theme's dormant light
    // half included, so a mode flip after re-import round-trips.
    NSDictionary<NSString *, id> *fields = [self sanitizedRecord:record];
    NSMutableDictionary<NSString *, NSData *> *entries = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *nameForValue = [NSMutableDictionary dictionary];
    for (NSString *key in self.imageFieldKeys) {
        NSString *reference = fields[key];
        if (nameForValue[reference]) {
            names[key] = nameForValue[reference];
            continue;
        }
        NSData *image = [self dataForReference:reference];
        if (!image) {
            continue;
        }
        NSString *entry = [[self archiveEntryStemForImageKey:key]
                stringByAppendingPathExtension:reference.pathExtension];
        entries[entry] = image;
        names[key] = entry;
        nameForValue[reference] = entry;
    }
    if (!entries.count) {
        return nil;
    }
    entries[@"theme.json"] = [self JSONDataForRecord:record name:name entryNames:names];
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
        // JSON carries no images: drop a custom reference nothing here holds.
        for (NSString *key in self.imageFieldKeys) {
            NSString *reference = record[key];
            if ([reference hasPrefix:@"custom:"] && [self referenceIsMissing:reference]) {
                [record removeObjectForKey:key];
            }
        }
        return record;
    }
    if (data.length > VibeThemeArchiveByteCap()) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:1 userInfo:nil];
        }
        return nil;
    }
    NSDictionary<NSString *, NSData *> *entries = VibeUnzipData(data);
    // Skip a Finder zip's AppleDouble sidecars: __MACOSX/._theme.json is not
    // JSON. Sorted, first name winning, so duplicate base names resolve
    // deterministically.
    NSMutableDictionary<NSString *, NSData *> *byBaseName = [NSMutableDictionary dictionary];
    for (NSString *entry in [entries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *base = entry.lastPathComponent;
        if ([entry hasPrefix:@"__MACOSX/"] || [base hasPrefix:@"._"] || byBaseName[base]) {
            continue;
        }
        byBaseName[base] = entries[entry];
    }
    // theme.json wins; a hand-made archive falls back to the first JSON.
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
    // A reference here is a bare entry name, read from the RAW JSON because
    // the sanitizer dropped it. A prefix from a hand-edited file is ignored.
    NSDictionary<NSString *, NSString *> *references = [self rawImageReferencesInJSONData:json];
    for (NSString *key in self.imageFieldKeys) {
        NSString *reference = references[key];
        if (!reference) {
            continue;
        }
        NSString *entry = [reference componentsSeparatedByString:@":"].lastObject;
        // Stored as custom:<sha1>, a built-in's too: a slot name says nothing
        // about which build's Resources the bytes came from. A failing image
        // costs only its field, so its reason is not reported.
        NSData *image = byBaseName[entry];
        NSString *stored = image ? [self storeCustomImageData:image error:NULL] : nil;
        if (stored) {
            record[key] = stored;
        } else {
            [record removeObjectForKey:key];
        }
    }
    return record;
}

@end
