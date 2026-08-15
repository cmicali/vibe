//
//  TrackCommands.m
//  Vibe
//

#import "TrackCommands.h"
#import "AudioTrack.h"

@implementation TrackCommands

+ (void)revealInFinder:(AudioTrack *)track {
    NSURL *url = track.url;
    if (url) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
    }
}

+ (void)copyFile:(AudioTrack *)track {
    NSURL *url = track.url;
    if (url) {
        [self writeToPasteboard:url];
    }
}

+ (void)copyName:(AudioTrack *)track {
    NSString *name = track.singleLineTitle;
    if (name.length) {
        [self writeToPasteboard:name];
    }
}

+ (void)writeToPasteboard:(id<NSPasteboardWriting>)object {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard writeObjects:@[object]];
}

@end
