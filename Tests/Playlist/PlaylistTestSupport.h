
#import <Foundation/Foundation.h>

#import "AudioTrack.h"
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

// "a b c" as three rows, a.mp3, b.mp3 and c.mp3.
static inline NSArray<AudioTrack *> *TracksNamed(NSString *names) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *name in [names componentsSeparatedByString:@" "]) {
        [urls addObject:URLNamed([name stringByAppendingString:@".mp3"])];
    }
    return Rows(urls);
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

// Keyed as both shells key theirs, so it has lookup by file.
static inline Playlist<AudioTrack *> *NewPlaylist(void) {
    return [[Playlist<AudioTrack *> alloc] initWithURLKey:^NSURL *(AudioTrack *track) {
        return track.url;
    } sourceKey:^NSString *(AudioTrack *track) {
        return track.sourceKey;
    }];
}

// The convert swap's replacement block.
static inline AudioTrack *(^ReplacementAt(NSURL *url))(AudioTrack *) {
    return ^AudioTrack *(AudioTrack *outgoing) {
        return [outgoing replacementAtURL:url];
    };
}

static inline Playlist<AudioTrack *> *PlaylistWithFiles(NSArray<NSString *> *filenames) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *name in filenames) {
        [urls addObject:URLNamed(name)];
    }
    Playlist<AudioTrack *> *playlist = NewPlaylist();
    [playlist replaceAllWithTracks:Rows(urls) startingAtIndex:NSNotFound];
    return playlist;
}
