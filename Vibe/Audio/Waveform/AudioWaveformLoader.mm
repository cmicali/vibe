//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioWaveformLoader.h"

@implementation AudioWaveformLoader

- (instancetype)initWithDelegate:(id <AudioWaveformLoaderDelegate>)delegate {
    self = [super init];
    if (self) {
        self.isCancelled = NO;
        self.isComplete = NO;
        self.delegate = delegate;
    }
    return self;
}

- (void)cancel {
    // Always set isCancelled — even after completion — so a completed-but-
    // undelivered waveform for a previous track is dropped at delivery time.
    self.isCancelled = YES;
}

- (CodableAudioWaveform *)load:(NSString *)filename {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

@end
