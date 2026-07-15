//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Kept a forward declaration (its header defines C++ classes): importing
// AudioWaveform.h here would force every transitive importer to compile as
// ObjC++ (same pattern as AudioWaveformCache.h).
@class CodableAudioWaveform;
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
