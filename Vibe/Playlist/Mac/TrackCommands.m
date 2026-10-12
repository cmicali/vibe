//
//  TrackCommands.m
//  Vibe
//

#import "TrackCommands.h"
#import "AudioTrack.h"
#import "NSURLUtil.h"

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
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSURL *url in [self urlsOfTracks:tracks]) {
        if ([self handsOutURL:url]) {
            [urls addObject:url];
        }
    }
    if (urls.count) {
        [self writeToPasteboard:urls];
    }
    else if (tracks.count) {
        // Validation reads no file, so the item stays enabled over a
        // placeholder. The beep says nothing was copied.
        NSBeep();
    }
}

+ (BOOL)handsOutURL:(NSURL *)url {
    return url.isFileURL && ![NSURLUtil isRemotePlaceholderFile:url];
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
