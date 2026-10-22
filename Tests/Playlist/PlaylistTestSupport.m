//
//  PlaylistTestSupport.m
//  VibeTests
//

#import "PlaylistTestSupport.h"

@implementation TestRow

+ (TestRow *)withURL:(NSURL *)url {
    return [[TestRow alloc] initWithURL:url cueStart:0 cueEnd:0];
}

- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)start cueEnd:(NSUInteger)end {
    self = [super init];
    if (self) {
        _url = [url copy];
        _cueStart = start;
        _cueEnd = end;
        _sourceKey = start > 0 || end > 0
                ? [NSString stringWithFormat:@"%@#%lu-%lu", url.path, (unsigned long)start, (unsigned long)end]
                : url.path;
        _duration = -1;
    }
    return self;
}

- (TestRow *)replacementAtURL:(NSURL *)url {
    TestRow *row = [[TestRow alloc] initWithURL:url cueStart:_cueStart cueEnd:_cueEnd];
    row.duration = self.duration;
    return row;
}

@end

@implementation RecordingObserver

- (instancetype)init {
    self = [super init];
    if (self) {
        _events = [NSMutableArray array];
    }
    return self;
}

- (void)playlistDidReplaceAllTracks:(Playlist *)playlist {
    self.lastReplacementGeneration = playlist.structureGeneration;
    [self.events addObject:@"replaceAll"];
}

- (void)playlist:(Playlist *)playlist didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [self.events addObject:[NSString stringWithFormat:@"append %lu-%lu",
                            (unsigned long)indexes.firstIndex, (unsigned long)indexes.lastIndex]];
}

- (void)playlist:(Playlist *)playlist didReplaceTrackAtIndex:(NSUInteger)index {
    [self.events addObject:[NSString stringWithFormat:@"replace %lu", (unsigned long)index]];
}

- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex {
    [self.events addObject:[NSString stringWithFormat:@"index %lu->%lu",
                            (unsigned long)previousIndex, (unsigned long)playlist.currentIndex]];
}

- (void)playlist:(Playlist *)playlist didRemoveTracksAtIndexes:(NSIndexSet *)indexes {
    // Records the final state: the model is coherent BEFORE the observer is called.
    [self.events addObject:[NSString stringWithFormat:@"remove %@ cursor %lu count %lu",
                            RowsString(indexes),
                            (unsigned long)playlist.currentIndex,
                            (unsigned long)playlist.count]];
}

- (void)playlist:(Playlist *)playlist didInsertTracksAtIndexes:(NSIndexSet *)indexes {
    [self.events addObject:[NSString stringWithFormat:@"insert %@ cursor %lu count %lu",
                            RowsString(indexes),
                            (unsigned long)playlist.currentIndex,
                            (unsigned long)playlist.count]];
}

- (void)playlist:(Playlist *)playlist
        didMoveTracksFromIndexes:(NSIndexSet *)sourceIndexes
                       toIndexes:(NSIndexSet *)destinationIndexes {
    [self.events addObject:[NSString stringWithFormat:@"move %@->%@ cursor %lu count %lu",
                            RowsString(sourceIndexes),
                            RowsString(destinationIndexes),
                            (unsigned long)playlist.currentIndex,
                            (unsigned long)playlist.count]];
}

@end
