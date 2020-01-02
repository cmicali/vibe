//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioWaveform.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioPlayer;

@protocol AudioWaveformLoaderDelegate;
@class AudioTrack;

#pragma mark - Waveform Loader

@interface AudioWaveformLoader : NSObject

@property (nullable, weak) id <AudioWaveformLoaderDelegate> delegate;

- (instancetype)initWithDelegate:(id <AudioWaveformLoaderDelegate>)delegate;

@property (atomic) BOOL isFinished;
@property (atomic) BOOL isCancelled;

- (BOOL)cancel;
- (AudioWaveform *)load:(NSString *)filename;
- (AudioWaveformCacheChunk)getChunkForAudioBuffer:(float *)buffer length:(NSUInteger)length numChannels:(NSUInteger)channels;

@end

@protocol AudioWaveformLoaderDelegate <NSObject>
@optional

- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(AudioWaveform *)waveform didLoadData:(float)percentLoaded;

@end

#pragma mark - Waveform Cache

@protocol AudioWaveformCacheDelegate;

@interface AudioWaveformCache : NSObject

@property (nullable, weak) id <AudioWaveformCacheDelegate> delegate;

- (void)loadWaveformForTrack:(AudioTrack *)track;

@end

@protocol AudioWaveformCacheDelegate <NSObject>
@optional

- (void)audioWaveform:(AudioWaveform *)waveform didLoadData:(float)percentLoaded;

@end

NS_ASSUME_NONNULL_END
