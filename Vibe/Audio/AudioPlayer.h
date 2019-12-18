//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioPlayerDelegate;
@class AudioTrack;

@interface AudioPlayer : NSObject

@property (nonatomic) CFTimeInterval currentTime;
@property (nonatomic) CFTimeInterval totalTime;

@property (nonatomic) SInt64 currentFrame;
@property (nonatomic) SInt64 totalFrames;

@property (nonatomic) float fractionComplete;

@property (nullable, weak) id <AudioPlayerDelegate> delegate;

- (BOOL)playURL:(NSURL *)url;
- (void)loadMetadata:(NSArray<AudioTrack *> *)tracks;

- (void)playPause;
- (void)stop;
- (void)seek:(float)position;
- (bool)supportsSeeking;

@end

@protocol AudioPlayerDelegate <NSObject>
@optional

- (void)audioPlayer:(AudioPlayer *)player didStartPlayingURL:(NSURL *)url didPlay:(BOOL)play;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartRenderingURL:(NSURL *)url;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishRenderingURL:(NSURL *)url;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartDecodingURL:(NSURL *)url;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishDecodingURL:(NSURL *)url;

- (void)audioPlayer:(AudioPlayer *)audioPlayer didMakePlaybackProgress:(NSURL *)url;
- (void)audioPlayer:(AudioPlayer *)audioPlayer didLoadMetadata:(NSURL *)url;


@end

NS_ASSUME_NONNULL_END