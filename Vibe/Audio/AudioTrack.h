//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;

@interface AudioTrack : NSObject

@property (copy) NSURL *url;

@property(nonatomic, strong) AudioTrackMetadata *metadata;

- (instancetype)initWithUrl:(NSURL *)url;

+ (AudioTrack *)withURL:(NSURL *)url;

- (NSString *)title;

+ (AudioTrack *)empty;

- (NSString *)artist;
- (NSImage *)albumArt;

@end

NS_ASSUME_NONNULL_END