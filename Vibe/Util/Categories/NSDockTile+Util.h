//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface NSDockTile (Util)

+ (void)resetToAppIcon;

+ (void)setDockIcon:(NSImage *)image;
@end