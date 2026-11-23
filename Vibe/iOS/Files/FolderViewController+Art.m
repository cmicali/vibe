//
//  FolderViewController+Art.m
//  Vibe (iOS)
//

#import "FolderViewControllerInternal.h"
#import "AudioTrackMetadata.h"
#import "VibeBrowserArtHolder.h"

// Rows past each end of the screen whose art is asked for with the visible ones.
static const NSInteger kArtRowMargin = 20;

@implementation FolderViewController (Art)

// The stack's one cache, asked of the host only once a row needs art. Nil
// from a host with no art: every row keeps its tile.
- (AudioTrackMetadataCache *)stackArtCache {
    if (!_artCache && [_host respondsToSelector:@selector(artCache)]) {
        _artCache = _host.artCache;
    }
    return _artCache;
}

// TRAP: send remote and dataless rows only to loadCachedMetadata:.
// A normal cache miss would fetch tags or download the file just to browse it.
- (void)loadArtForVisibleRows {
    if (_songFiles.count == 0 || !self.viewIfLoaded.window || ![_host respondsToSelector:@selector(artCache)]) {
        return;
    }
    [self.tableView layoutIfNeeded];
    NSInteger first = NSIntegerMax;
    NSInteger last = -1;
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        if (indexPath.section == VibeBrowserSectionFiles) {
            first = MIN(first, indexPath.row);
            last = MAX(last, indexPath.row);
        }
    }
    if (last < 0) {
        return;
    }
    first = MAX(0, first - kArtRowMargin);
    last = MIN((NSInteger)_files.count - 1, last + kArtRowMargin);
    NSMutableArray<id<AudioTrackMetadataHolder>> *parse = [NSMutableArray array];
    NSMutableArray<id<AudioTrackMetadataHolder>> *cacheOnly = [NSMutableArray array];
    for (NSInteger row = first; row <= last; row++) {
        NSURL *url = _files[(NSUInteger)row];
        if (![_songFiles containsObject:url]) {
            continue;
        }
        id<AudioTrackMetadataHolder> track = _artTracks[url];
        if (!track) {
            if (!_artTracks) {
                _artTracks = [NSMutableDictionary dictionary];
            }
            track = [_host respondsToSelector:@selector(artHolderForFileURL:)]
                    ? [_host artHolderForFileURL:url] : [[VibeBrowserArtHolder alloc] initWithURL:url];
            _artTracks[url] = track;
        }
        if (track.metadata) {
            continue;
        }
        if ([_localFiles containsObject:url]) {
            [parse addObject:track];
        }
        else if (![_cacheOnlyAsked containsObject:url]) {
            [_cacheOnlyAsked addObject:url];
            [cacheOnly addObject:track];
        }
    }
    if (parse.count == 0 && cacheOnly.count == 0) {
        return;
    }
    AudioTrackMetadataCache *cache = [self stackArtCache];
    cache.delegate = self;
    if (parse.count > 0) {
        [cache loadMetadata:parse];
    }
    [cache loadCachedMetadata:cacheOnly];
}

- (void)redrawVisibleRowsShowing:(AudioTrackMetadata *)metadata {
    if (!metadata || _artTracks.count == 0 || !self.viewIfLoaded.window) {
        return;
    }
    NSMutableArray<NSIndexPath *> *rows = [NSMutableArray array];
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        if (indexPath.section == VibeBrowserSectionFiles && (NSUInteger)indexPath.row < _files.count
                && _artTracks[_files[(NSUInteger)indexPath.row]].metadata == metadata) {
            [rows addObject:indexPath];
        }
    }
    if (rows.count > 0) {
        [self.tableView reconfigureRowsAtIndexPaths:rows];
    }
}

// The tags landed; the row's next draw asks for the thumbnail, whose pixels
// arrive by the notification below.
- (void)didLoadMetadata:(id<AudioTrackMetadataHolder>)track {
    [self redrawVisibleRowsShowing:track.metadata];
}

- (void)artThumbnailDidLoad:(NSNotification *)notification {
    [self redrawVisibleRowsShowing:notification.object];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self loadArtForVisibleRows];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self loadArtForVisibleRows];
    }
}

@end
