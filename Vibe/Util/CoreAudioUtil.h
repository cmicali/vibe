//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

@protocol CoreAudioSystemOutputDeviceDelegate;

@interface CoreAudioUtil : NSObject

+ (void)listenForSystemOutputDeviceChanges:(id <CoreAudioSystemOutputDeviceDelegate>)delegate;
+ (void)audioOutputDevices;
+ (AudioDeviceID)audioDeviceIDforUID:(NSString *)uid;
+ (void)supportedSampleRatesForOutputDevice:(NSString *)uid;
+ (Float64)setSampleRate:(int)rate forDeviceUID:(NSString *)uid;

@end

@protocol CoreAudioSystemOutputDeviceDelegate <NSObject>
- (void)systemAudioOutputDeviceDidChange;
@optional

@end