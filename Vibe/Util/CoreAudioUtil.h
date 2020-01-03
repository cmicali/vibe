//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol CoreAudioSystemOutputDeviceDelegate;

@interface CoreAudioUtil : NSObject

+ (void)listenForSystemOutputDeviceChanges:(id <CoreAudioSystemOutputDeviceDelegate>)delegate;
+ (NSArray<NSNumber *> *)supportedSampleRatesForOutputDevice:(NSString *)uid;

+ (BOOL)setBestSampleRate:(double)rate forDeviceUID:(NSString *)uid;

@end

@protocol CoreAudioSystemOutputDeviceDelegate <NSObject>
- (void)systemAudioOutputDeviceDidChange;
@optional

@end
