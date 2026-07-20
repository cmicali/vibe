//
//  main.m
//  Vibe
//
//  Created by Christopher Micali on 12/14/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

#if DEBUG
#import "DebugUtil.h"
#endif

// No main nib: the delegate is created here (NSApplication.delegate is weak,
// so this global keeps it alive) and builds the menu bar and window itself.
static AppDelegate *appDelegate;

int main(int argc, const char * argv[]) {
#if DEBUG
    // Debug CLI client: sends a command to the running app and prints the
    // response. Exits before NSApplicationMain — no second app instance.
    if (argc >= 2 && strcmp(argv[1], "--debug-cmd") == 0) {
        return VibeDebugCommandClientMain(argc, argv);
    }
#else
    // Say so instead of silently launching the app and printing nothing —
    // the flag against a Release binary otherwise looks like a hang.
    if (argc >= 2 && strcmp(argv[1], "--debug-cmd") == 0) {
        fprintf(stderr, "vibe: --debug-cmd requires a Debug build\n");
        return 1;
    }
#endif
    @autoreleasepool {
        appDelegate = [[AppDelegate alloc] init];
        NSApplication.sharedApplication.delegate = appDelegate;
    }
    return NSApplicationMain(argc, argv);
}
