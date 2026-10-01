//
//  TrackCommands.m
//  Vibe
//

#import "TrackCommands.h"
#import "AudioTrack.h"

@implementation TrackCommands

// One per file, in row order: a sheet's rows share theirs.
+ (NSArray<NSURL *> *)urlsOfTracks:(NSArray<AudioTrack *> *)tracks {
    NSMutableOrderedSet<NSURL *> *urls = [NSMutableOrderedSet orderedSetWithCapacity:tracks.count];
    for (AudioTrack *track in tracks) {
        NSURL *url = track.url;
        if (url) {
            [urls addObject:url];
        }
    }
    return urls.array;
}

+ (void)revealInFinder:(NSArray<AudioTrack *> *)tracks {
    NSArray<NSURL *> *urls = [self urlsOfTracks:tracks];
    if (urls.count) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
    }
}

+ (void)copyFiles:(NSArray<AudioTrack *> *)tracks {
    NSArray<NSURL *> *urls = [self urlsOfTracks:tracks];
    if (urls.count) {
        [self writeToPasteboard:urls];
    }
}

+ (void)copyNames:(NSArray<AudioTrack *> *)tracks {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:tracks.count];
    for (AudioTrack *track in tracks) {
        NSString *name = track.singleLineTitle;
        if (name.length) {
            [names addObject:name];
        }
    }
    if (names.count) {
        [self writeToPasteboard:@[[names componentsJoinedByString:@"\n"]]];
    }
}

+ (void)writeToPasteboard:(NSArray<id<NSPasteboardWriting>> *)objects {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard writeObjects:objects];
}

@end
