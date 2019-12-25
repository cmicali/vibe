//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AudioPlayer;

struct MinMax {
    float min;
    float max;
};
typedef struct CG_BOXABLE MinMax MinMax;

@interface AudioWaveform : NSObject

- (MinMax)getMinMax:(NSUInteger)index;

- (id)initWithFilename:(NSString *)filename;

@end