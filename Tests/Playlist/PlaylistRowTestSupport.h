//
//  PlaylistRowTestSupport.h
//  VibeTests
//
//  The shells' tests' rows: AudioTrack rows named by file, and the row sets
//  they compare. The queue's own tests use PlaylistTestSupport.h, over rows of
//  their own.
//

#import <Foundation/Foundation.h>

#import "AudioTrack.h"

// "1" or "0,2".
static inline NSString *RowsString(NSIndexSet *indexes) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [parts addObject:[NSString stringWithFormat:@"%lu", (unsigned long)index]];
    }];
    return [parts componentsJoinedByString:@","];
}

static inline NSURL *URLNamed(NSString *filename) {
    NSString *path = [@"/private/tmp/vibe-tests/" stringByAppendingString:filename];
    return [NSURL fileURLWithPath:path];
}

// "a b c" as three rows, a.mp3, b.mp3 and c.mp3.
static inline NSArray<AudioTrack *> *TracksNamed(NSString *names) {
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray array];
    for (NSString *name in [names componentsSeparatedByString:@" "]) {
        [rows addObject:[AudioTrack withURL:URLNamed([name stringByAppendingString:@".mp3"])]];
    }
    return rows;
}

// The rows' file stems, space-separated: "a b c".
static inline NSString *NamesOf(NSArray<AudioTrack *> *tracks) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (AudioTrack *track in tracks) {
        [names addObject:track.url.lastPathComponent.stringByDeletingPathExtension];
    }
    return [names componentsJoinedByString:@" "];
}

static inline NSIndexSet *RowSet(NSUInteger index) {
    return [NSIndexSet indexSetWithIndex:index];
}

static inline NSIndexSet *RowRange(NSUInteger location, NSUInteger length) {
    return [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(location, length)];
}

static inline NSIndexSet *RowSetOf(NSArray<NSNumber *> *rows) {
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    for (NSNumber *row in rows) {
        [indexes addIndex:row.unsignedIntegerValue];
    }
    return indexes;
}

static inline AudioTrack *CueRowOf(NSString *filename, NSUInteger start, NSUInteger end) {
    return [[AudioTrack alloc] initWithURL:URLNamed(filename) cueStart:start cueEnd:end
                                     title:@"Row" performer:nil sheet:URLNamed(@"album.cue")
                               trackNumber:1];
}
