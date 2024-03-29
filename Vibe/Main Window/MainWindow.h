//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol FileDropDelegate;

@interface MainWindow : NSWindow <NSDraggingDestination>

@property (nullable, weak) id <FileDropDelegate> dropDelegate;

- (BOOL)isPlaylistShown;

- (IBAction)setSmallSize:(BOOL)animate;
- (IBAction)setLargeSize:(BOOL)animate;

- (IBAction)toggleSize:(id)sender;

- (void)loadSettings;

@end

@protocol FileDropDelegate <NSObject>
@optional

- (void)mainWindow:(MainWindow *)mainWindow filesDropped:(NSArray<NSURL *>*)urls;

@end

NS_ASSUME_NONNULL_END
