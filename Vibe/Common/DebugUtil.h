//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#if DEBUG

// Installs a notification hook that dumps the frontmost window to a PNG.
// Trigger from a terminal:
//
//     notifyutil -p com.vibe.debug.screenshot
//
// then read vibe-screenshot.png from the app container's tmp directory
// (the app is sandboxed, so /tmp is not writable):
//
//     ~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/
//
// Renders the window's *presentation* layer tree in-process — no window
// server capture, so it needs no screen-recording permission, works with the
// display asleep or the window occluded, and captures in-flight Core
// Animation (e.g. the artwork cross-fade) mid-animation. Metal content (the
// About window) does not render this way.
void VibeInstallDebugScreenshotHook(void);

#endif
