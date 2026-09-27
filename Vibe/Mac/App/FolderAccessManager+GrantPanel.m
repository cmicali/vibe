//
//  FolderAccessManager+GrantPanel.m
//  Vibe
//

#import "FolderAccessManager+GrantPanel.h"
#import "VibeStrings.h"
#import <AppKit/AppKit.h>

@implementation FolderAccessManager (GrantPanel)

// Blocking on main is safe: nothing on main waits synchronously on the
// expansion queue. Powerbox prompts must not stack, so walks serialize here on
// a private gate; a monitor on the manager would be reachable, and so
// deadlockable, from anywhere.
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
        // Reading panel.URL is what attaches the sandbox extension.
        granted = [panel runModal] == NSModalResponseOK && panel.URL != nil;
        if (granted) {
            LogInfo(@"Playlist folder access granted: %@", panel.URL.path);
            // The extension lasts only this process, and the auto-add funnel
            // sees the playlist file, not this folder.
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
