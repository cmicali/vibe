//
//  VibePerfPlaylist.mm
//  VibePerf
//
//  The playlist model's edits on a 100,000-row playlist.
//

#import "VibePerf.h"

#import "AudioTrack.h"
#import "Playlist.h"

#include <memory>

// MARK: - The playlist model

static void VibePerfRegisterPlaylist(void) {
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
            *playlist = [[Playlist alloc] init];
            [*playlist replaceAllWithTracks:tracks];
        }
        return 20;
    };
    for (double at : {0.0, 0.5, 0.99}) {
        const char *where = at == 0 ? "head" : at == 0.5 ? "middle" : "tail";
        VibePerfAdd("playlist-edit", std::string("100k-") + where, "edit", prepare, [playlist, at]() {
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
}

VIBE_PERF_REGISTER(VibePerfRegisterPlaylist)
