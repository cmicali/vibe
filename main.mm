//
//  main.m
//  Vibe
//
//  Created by Christopher Micali on 12/14/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

// No main nib: the delegate is created here (NSApplication.delegate is weak,
// so this global keeps it alive) and builds the menu bar and window itself.
static AppDelegate *appDelegate;

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        appDelegate = [[AppDelegate alloc] init];
        NSApplication.sharedApplication.delegate = appDelegate;
    }
    return NSApplicationMain(argc, argv);
}
