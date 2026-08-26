//
//  TrackCommands.m
//  Vibe
//

#import "TrackCommands.h"
#import "AudioTrack.h"

@implementation TrackCommands

+ (NSArray<NSURL *> *)urlsOfTracks:(NSArray<AudioTrack *> *)tracks {
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:tracks.count];
    for (AudioTrack *track in tracks) {
        NSURL *url = track.url;
        if (url) {
            [urls addObject:url];
        }
    }
    return urls;
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
