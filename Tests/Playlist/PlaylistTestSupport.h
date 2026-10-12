//
//  PlaylistTestSupport.h
//  VibeTests
//
//  The helpers the Playlist tests share: rows at fixed paths, index sets, and
//  an observer that records each event. PlaylistTests, PlaylistEditTests and
//  PlaylistRepeatAndShuffleTests use them.
//

#import <Foundation/Foundation.h>

#import "Playlist.h"

// "1" or "0,2".
static inline NSString *RowsString(NSIndexSet *indexes) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [parts addObject:[NSString stringWithFormat:@"%lu", (unsigned long)index]];
    }];
    return [parts componentsJoinedByString:@","];
}

@interface RecordingObserver : NSObject <PlaylistObserver>
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic) NSUInteger lastReplacementGeneration;
@end

static inline NSURL *URLNamed(NSString *filename) {
    NSString *path = [@"/private/tmp/vibe-tests/" stringByAppendingString:filename];
    return [NSURL fileURLWithPath:path];
}

static inline NSArray<AudioTrack *> *Rows(NSArray<NSURL *> *urls) {
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        [rows addObject:[AudioTrack withURL:url]];
    }
    return rows;
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

static inline Playlist *PlaylistWithFiles(NSArray<NSString *> *filenames) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *name in filenames) {
        [urls addObject:URLNamed(name)];
    }
    Playlist *playlist = [Playlist new];
    [playlist replaceAllWithTracks:Rows(urls) startingAtIndex:NSNotFound];
    return playlist;
}
