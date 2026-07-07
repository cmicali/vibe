//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioWaveform.h"

NS_ASSUME_NONNULL_BEGIN

@protocol AudioWaveformLoaderDelegate;

@interface AudioWaveformLoader : NSObject

@property (nullable, weak) id <AudioWaveformLoaderDelegate> delegate;

- (instancetype)initWithDelegate:(id <AudioWaveformLoaderDelegate>)delegate;

@property (atomic) BOOL isComplete;
@property (atomic) BOOL isCancelled;

- (BOOL)cancel;
- (nullable CodableAudioWaveform *)load:(NSString *)filename;

@end

@protocol AudioWaveformLoaderDelegate <NSObject>
@optional

- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded;

@end

NS_ASSUME_NONNULL_END
