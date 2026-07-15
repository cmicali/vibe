//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface NSImage (Util)

// Redraws the image at newSize into an sRGB bitmap. Returns nil if the
// bitmap or its drawing context can't be created — never falls back to the
// full-size original (callers resize precisely to shed its memory).
- (nullable NSImage *)resizedImage:(NSSize)newSize;
@end
