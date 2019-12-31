//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioPlayer;

struct MinMax {
    float min;
    float max;
};
typedef struct CG_BOXABLE MinMax MinMax;

@protocol AudioWaveformDelegate;

@interface AudioWaveform : NSObject <NSCoding>

@property (copy) NSString *fileHash;

@property (atomic) BOOL isFinished;
@property (atomic) BOOL isCancelled;

@property (nullable, weak) id <AudioWaveformDelegate> delegate;

- (BOOL)load:(NSString *)filename;
- (void)cancel;

- (MinMax)getMinMax:(NSUInteger)index;

@end


@protocol AudioWaveformDelegate <NSObject>
@optional

- (void)audioWaveform:(AudioWaveform *)waveform didLoadData:(float)percentLoaded;

@end

NS_ASSUME_NONNULL_END
