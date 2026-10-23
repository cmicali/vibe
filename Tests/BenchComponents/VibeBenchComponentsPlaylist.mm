//
//  VibeBenchComponentsPlaylist.mm
//  VibeBenchComponents
//
//  The playlist model's edits on a 100,000-row playlist.
//

#import "VibeBenchComponents.h"

#import "AudioTrack.h"
#import "Playlist.h"

#include <memory>

// MARK: - The playlist model

static void VibeBenchComponentsRegisterPlaylist(void) {
    // A 100,000-row playlist; one repetition is five single-row removals each
    // undone by its insert, and five single-row moves there and back, at one
    // place in the list.
    auto playlist = std::make_shared<Playlist *>();
    auto prepare = [playlist]() -> double {
        if (!*playlist) {
            NSMutableArray<AudioTrack *> *tracks = [NSMutableArray arrayWithCapacity:100000];
            for (NSUInteger i = 0; i < 100000; i++) {
                NSString *path = [NSString stringWithFormat:@"/Volumes/Music/Artist %03lu/Album %04lu/Track %06lu.flac",
                                                            (unsigned long)(i / 1000), (unsigned long)(i / 12), (unsigned long)i];
                [tracks addObject:[AudioTrack withURL:[NSURL fileURLWithPath:path isDirectory:NO]]];
            }
#if VIBE_BENCH_COMPONENTS_PLAYLIST_KEYS
            // Keyed as the shells key theirs, so the URL index is built and
            // renumbered as in the app.
            *playlist = [[Playlist<AudioTrack *> alloc] initWithURLKey:^NSURL *(AudioTrack *track) {
                return track.url;
            } sourceKey:^NSString *(AudioTrack *track) {
                return track.sourceKey;
            }];
#else
            *playlist = [[Playlist alloc] init];
#endif
            [*playlist replaceAllWithTracks:tracks startingAtIndex:NSNotFound];
        }
        return 20;
    };
    for (double at : {0.0, 0.5, 0.99}) {
        const char *where = at == 0 ? "head" : at == 0.5 ? "middle" : "tail";
        VibeBenchComponentsAdd("playlist-edit", std::string("100k-") + where, "edit", prepare, [playlist, at]() {
            Playlist *list = *playlist;
            NSUInteger row = (NSUInteger)(at * (list.count - 1));
            for (int i = 0; i < 5; i++) {
                NSIndexSet *one = [NSIndexSet indexSetWithIndex:row + i];
                NSArray<AudioTrack *> *removed = [list removeTracksAtIndexes:one];
                [list insertTracks:removed atIndexes:one];
                NSIndexSet *to = [NSIndexSet indexSetWithIndex:row + i + 5];
                [list moveTracksAtIndexes:one toIndexes:to];
                [list moveTracksAtIndexes:to toIndexes:one];
            }
        });
    }

    VibeBenchComponentsAdd("playlist-edit", "100k-bulk-1k", "edit", [prepare]() -> double {
        prepare();
        return 4;
    }, [playlist]() {
        Playlist *list = *playlist;
        NSMutableIndexSet *source = [NSMutableIndexSet indexSet];
        for (NSUInteger i = 0; i < 1000; i++) [source addIndex:i * 97];
        NSArray<AudioTrack *> *removed = [list removeTracksAtIndexes:source];
        VibeBenchComponentsRequire(removed.count == 1000, "bulk removal lost rows");
        [list insertTracks:removed atIndexes:source];
        NSIndexSet *destination = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(50000, 1000)];
        VibeBenchComponentsRequire([list moveTracksAtIndexes:source toIndexes:destination] &&
                                   [list moveTracksAtIndexes:destination toIndexes:source] && list.count == 100000,
                                   "bulk move failed");
    });
    VibeBenchComponentsAdd("playlist-lookup", "100k", "lookup", [prepare]() -> double {
        prepare();
        return 2000;
    }, [playlist]() {
        for (NSUInteger i = 0; i < 1000; i++) {
            NSUInteger index = (i * 7919) % 100000;
            AudioTrack *track = [*playlist trackAtIndex:index];
            VibeBenchComponentsRequire([*playlist getIndexForTrack:track] == (NSInteger)index &&
                                       [[*playlist indexesOfTracksWithURL:track.url] containsIndex:index],
                                       "playlist lookup lost a row");
        }
    });
    VibeBenchComponentsAdd("playlist", "100k-shuffle-walk", "shuffle", [prepare]() -> double {
        prepare();
        return 1;
    }, [playlist]() {
        Playlist *list = *playlist;
        list.currentIndex = 0;
        __block uint32_t seed = 12345;
        list.randomBelow = ^uint32_t(uint32_t upper) {
            seed = seed * 1664525u + 1013904223u;
            return seed % upper;
        };
        list.shuffleEnabled = YES;
        for (int i = 0; i < 1000; i++) VibeBenchComponentsRequire([list next], "shuffle ended early");
        for (int i = 0; i < 1000; i++) VibeBenchComponentsRequire([list previous], "shuffle history ended early");
        list.shuffleEnabled = NO;
    });
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterPlaylist)
