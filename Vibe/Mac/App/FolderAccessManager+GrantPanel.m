//
//  FolderAccessManager+GrantPanel.m
//  Vibe
//

#import "FolderAccessManager+GrantPanel.h"
#import "VibeStrings.h"
#import <AppKit/AppKit.h>

@implementation FolderAccessManager (GrantPanel)

// Safe to block on main from an expansion worker: every caller enters the
// expansion queue with an async submission, never the reverse.
//
// Folder walks are concurrent, but powerbox prompts must not stack inside one
// another's modal loops, so this uncommon path serializes on a private gate.
// Private deliberately: holding a lock across a modal run loop is a long hold,
// and a monitor on the manager would be reachable — and so deadlockable —
// from anywhere.
- (BOOL)requestAccessForPlaylistFolder:(NSURL *)playlistURL {
    NSAssert(!NSThread.isMainThread, @"the playlist grant blocks on the main thread");
    static dispatch_semaphore_t grantGate;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        grantGate = dispatch_semaphore_create(1);
    });
    __block BOOL granted = NO;
    dispatch_semaphore_wait(grantGate, DISPATCH_TIME_FOREVER);
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = NO;
        panel.canChooseDirectories = YES;
        panel.allowsMultipleSelection = NO;
        panel.directoryURL = playlistURL.URLByDeletingLastPathComponent;
        panel.message = [NSString stringWithFormat:STR_PLAYLIST_GRANT_MESSAGE,
                                                   VibeAppName(), playlistURL.lastPathComponent];
        panel.prompt = STR_PLAYLIST_GRANT_BUTTON;
        // Reading panel.URL is what attaches the powerbox's sandbox extension
        // to the process, not just running the panel.
        granted = [panel runModal] == NSModalResponseOK && panel.URL != nil;
        if (granted) {
            LogInfo(@"Playlist folder access granted: %@", panel.URL.path);
            // The powerbox extension lasts only this process. Bookmark the
            // folder like the open and drop funnels do, or every relaunch
            // re-prompts for it — the auto-add funnel never sees it, since
            // openURLs: gets the playlist file, not the granted directory.
            [self noteOpenedURLs:@[panel.URL]];
        }
        else {
            LogInfo(@"Playlist folder access declined for %@", playlistURL.lastPathComponent);
        }
    });
    dispatch_semaphore_signal(grantGate);
    return granted;
}

@end
