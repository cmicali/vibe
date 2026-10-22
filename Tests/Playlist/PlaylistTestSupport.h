
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

// The tests' own row: a file whole, or a window of one. The model reads it only
// through its key blocks, as it reads an app's row.
@interface TestRow : NSObject
+ (TestRow *)withURL:(NSURL *)url;
- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)start cueEnd:(NSUInteger)end;
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) NSUInteger cueStart;
@property (nonatomic, readonly) NSUInteger cueEnd;
// The path and the window, fixed at init.
@property (nonatomic, readonly) NSString *sourceKey;
// State the row carries, which a copy would drop.
@property (nonatomic) NSTimeInterval duration;
// A fresh row for this one's window at another URL, as the convert swap makes.
- (TestRow *)replacementAtURL:(NSURL *)url;
@end

static inline NSURL *URLNamed(NSString *filename) {
    NSString *path = [@"/private/tmp/vibe-tests/" stringByAppendingString:filename];
    return [NSURL fileURLWithPath:path];
}

static inline NSArray<TestRow *> *Rows(NSArray<NSURL *> *urls) {
    NSMutableArray<TestRow *> *rows = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        [rows addObject:[TestRow withURL:url]];
    }
    return rows;
}

// "a b c" as three rows, a.mp3, b.mp3 and c.mp3.
static inline NSArray<TestRow *> *TracksNamed(NSString *names) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *name in [names componentsSeparatedByString:@" "]) {
        [urls addObject:URLNamed([name stringByAppendingString:@".mp3"])];
    }
    return Rows(urls);
}

// The rows' file stems, space-separated: "a b c".
static inline NSString *NamesOf(NSArray<TestRow *> *tracks) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (TestRow *track in tracks) {
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

static inline TestRow *CueRowOf(NSString *filename, NSUInteger start, NSUInteger end) {
    return [[TestRow alloc] initWithURL:URLNamed(filename) cueStart:start cueEnd:end];
}

// Keyed by the URL and the source key, so it has lookup by file.
static inline Playlist<TestRow *> *NewPlaylist(void) {
    return [[Playlist<TestRow *> alloc] initWithURLKey:^NSURL *(TestRow *track) {
        return track.url;
    } sourceKey:^NSString *(TestRow *track) {
        return track.sourceKey;
    }];
}

// The convert swap's replacement block.
static inline TestRow *(^ReplacementAt(NSURL *url))(TestRow *) {
    return ^TestRow *(TestRow *outgoing) {
        return [outgoing replacementAtURL:url];
    };
}

static inline Playlist<TestRow *> *PlaylistWithFiles(NSArray<NSString *> *filenames) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *name in filenames) {
        [urls addObject:URLNamed(name)];
    }
    Playlist<TestRow *> *playlist = NewPlaylist();
    [playlist replaceAllWithTracks:Rows(urls) startingAtIndex:NSNotFound];
    return playlist;
}
