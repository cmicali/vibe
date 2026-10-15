//
//  OpenRecentMenuController.m
//  Vibe
//

#import "OpenRecentMenuController.h"
#import "AppDelegate.h"
#import "VibeStrings.h"

@implementation OpenRecentMenuController {
    __weak AppDelegate *_appDelegate;
}

- (instancetype)initWithAppDelegate:(AppDelegate *)appDelegate {
    self = [super init];
    if (self) {
        _appDelegate = appDelegate;
    }
    return self;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    // Autoenable would leave an empty list's Clear Menu an enabled no-op:
    // NSDocumentController always responds to clearRecentDocuments:.
    menu.autoenablesItems = NO;
    NSArray<NSURL *> *urls = [[NSDocumentController sharedDocumentController] recentDocumentURLs];
    // As every Open Recent: the file's icon, and a name two entries share
    // followed by its folder.
    NSCountedSet<NSString *> *names = [NSCountedSet set];
    for (NSURL *url in urls) {
        [names addObject:url.lastPathComponent];
    }
    for (NSURL *url in urls) {
        NSString *name = url.lastPathComponent;
        if ([names countForObject:name] > 1) {
            name = [NSString stringWithFormat:VibeNotLocalized(@"%@ — %@"), name,
                                              url.URLByDeletingLastPathComponent.lastPathComponent];
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name
                                                      action:@selector(openRecentDocument:)
                                               keyEquivalent:@""];
        NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:url.path];
        icon.size = NSMakeSize(16, 16);
        item.image = icon;
        item.target = _appDelegate;
        item.representedObject = url;
        [menu addItem:item];
    }
    if (urls.count > 0) {
        [menu addItem:[NSMenuItem separatorItem]];
    }
    NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:STR_MENU_FILE_OPEN_RECENT_CLEAR
                                                   action:@selector(clearRecentDocuments:)
                                            keyEquivalent:@""];
    clear.target = [NSDocumentController sharedDocumentController];
    clear.enabled = urls.count > 0;
    [menu addItem:clear];
}

// Without this, AppKit's key-equivalent scan rebuilds the menu on every
// keyDown. No item carries a key equivalent.
- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(_Nullable id *_Nonnull)target action:(_Nullable SEL *_Nonnull)action {
    return NO;
}

@end
