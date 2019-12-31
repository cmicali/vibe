//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadata : NSObject

@property (copy) NSString *title;
@property (copy) NSString *artist;
@property (assign) NSTimeInterval duration;

@property (strong) NSImage *albumArt;

+ (AudioTrackMetadata *)getMetadataForURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
