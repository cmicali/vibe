//
//  FLACFixtures.h
//  Vibe
//
//  What the embedded-sheet reader reads: VibeWriteFLACHeader writes a FLAC's
//  metadata blocks, and VibeFLACCueSheetBlock a binary CUESHEET block. They
//  write the bytes themselves, so they need no decoder.
//

#import <Foundation/Foundation.h>

static inline void VibeAppendBE64(NSMutableData *data, uint64_t value) {
    for (int shift = 56; shift >= 0; shift -= 8) {
        uint8_t byte = (uint8_t)(value >> shift);
        [data appendBytes:&byte length:1];
    }
}

// A binary CUESHEET block, CD-flagged. Each track is @[number, offset in
// samples, pregap, data]: a pregap > 0 writes INDEX 00 at the offset and
// INDEX 01 that many samples later, else INDEX 01 alone; data nonzero marks a
// non-audio track. The lead-out (170) follows at leadOut.
static inline NSData *VibeFLACCueSheetBlock(NSArray<NSArray<NSNumber *> *> *tracks, uint64_t leadOut) {
    NSMutableData *block = [NSMutableData dataWithLength:128];
    VibeAppendBE64(block, 88200);
    uint8_t flag = 0x80, count = (uint8_t)(tracks.count + 1), zero = 0;
    [block appendBytes:&flag length:1];
    [block increaseLengthBy:258];
    [block appendBytes:&count length:1];
    void (^track)(uint8_t, uint64_t, uint64_t, BOOL) = ^(uint8_t number, uint64_t offset, uint64_t pregap, BOOL data) {
        VibeAppendBE64(block, offset);
        [block appendBytes:&number length:1];
        [block increaseLengthBy:12];
        uint8_t type = data ? 0x80 : 0;
        [block appendBytes:&type length:1];
        [block increaseLengthBy:13];
        uint8_t indexes = number == 170 ? 0 : (pregap > 0 ? 2 : 1);
        [block appendBytes:&indexes length:1];
        for (uint8_t i = pregap > 0 ? 0 : 1; indexes > 0 && i <= 1; i++) {
            VibeAppendBE64(block, i == 0 ? 0 : pregap);
            [block appendBytes:&i length:1];
            [block appendBytes:&zero length:1];
            [block appendBytes:&zero length:1];
            [block appendBytes:&zero length:1];
        }
    };
    for (NSArray<NSNumber *> *t in tracks) {
        track(t[0].unsignedCharValue, t[1].unsignedLongLongValue, t[2].unsignedLongLongValue, t[3].boolValue);
    }
    track(170, leadOut, 0, NO);
    return block;
}

// A FLAC's metadata blocks and no playable audio: what the embedded-sheet
// reader reads. A picture comes first, so the reader must seek over it; the
// sheet rides as a CUESHEET Vorbis comment (cueText) and/or a binary block;
// id3 prefixes an ID3v2 tag; size > 0 extends the file sparse to that size.
static inline NSURL *VibeWriteFLACHeader(NSURL *url, uint32_t rate, NSString *cueText, NSData *cueBlock,
                                         BOOL id3, unsigned long long size) {
    NSMutableData *file = [NSMutableData data];
    if (id3) {
        const uint8_t tag[10] = {'I', 'D', '3', 4, 0, 0, 0, 0, 0, 20};
        [file appendBytes:tag length:sizeof tag];
        [file increaseLengthBy:20];
    }
    [file appendBytes:"fLaC" length:4];
    NSMutableArray<NSData *> *blocks = [NSMutableArray array];
    NSMutableArray<NSNumber *> *types = [NSMutableArray array];
    NSMutableData *info = [NSMutableData dataWithLength:34];
    uint8_t *bytes = (uint8_t *)info.mutableBytes;
    bytes[10] = (uint8_t)(rate >> 12);
    bytes[11] = (uint8_t)(rate >> 4);
    bytes[12] = (uint8_t)((rate & 0xf) << 4 | 0x02);
    [blocks addObject:info];
    [types addObject:@0];
    [blocks addObject:[NSMutableData dataWithLength:1000]];
    [types addObject:@6];
    if (cueText) {
        NSMutableData *comment = [NSMutableData data];
        NSArray<NSString *> *fields = @[@"TITLE=The Whole Album", [@"CUESHEET=" stringByAppendingString:cueText]];
        uint32_t vendor = 4, n = (uint32_t)fields.count;
        [comment appendBytes:&vendor length:4];
        [comment appendBytes:"vibe" length:4];
        [comment appendBytes:&n length:4];
        for (NSString *field in fields) {
            NSData *utf8 = [field dataUsingEncoding:NSUTF8StringEncoding];
            uint32_t length = (uint32_t)utf8.length;
            [comment appendBytes:&length length:4];
            [comment appendData:utf8];
        }
        [blocks addObject:comment];
        [types addObject:@4];
    }
    if (cueBlock) {
        [blocks addObject:cueBlock];
        [types addObject:@5];
    }
    for (NSUInteger i = 0; i < blocks.count; i++) {
        NSUInteger length = blocks[i].length;
        uint8_t header[4] = {(uint8_t)(types[i].unsignedCharValue | (i + 1 == blocks.count ? 0x80 : 0)),
                             (uint8_t)(length >> 16), (uint8_t)(length >> 8), (uint8_t)length};
        [file appendBytes:header length:4];
        [file appendData:blocks[i]];
    }
    const uint8_t frame[4] = {0xff, 0xf8, 0xc9, 0x18};
    [file appendBytes:frame length:sizeof frame];
    if (![file writeToURL:url atomically:YES]) {
        return nil;
    }
    if (size > file.length) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:NULL];
        [handle truncateAtOffset:size error:NULL];
        [handle closeAndReturnError:NULL];
    }
    return url;
}
