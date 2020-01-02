//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "bass.h"

@protocol BASSChannelDelegate;

@interface BassUtil : NSObject

+ (BASS_DEVICEINFO)infoForCurrentDevice;
+ (BASS_DEVICEINFO)infoForDevice:(DWORD)deviceId;
+ (NSString *)driverForCurrentDevice;

+ (void)rampVolumeToZero:(HCHANNEL)channel async:(BOOL)async;
+ (void)rampVolumeToNormal:(HCHANNEL)channel async:(BOOL)async;

+ (NSTimeInterval)getChannelPosition:(HCHANNEL)channel;
+ (void)setChannelPosition:(HCHANNEL)channel position:(NSTimeInterval)pos;

+ (BOOL)setChannelDelegate:(id <BASSChannelDelegate>)delegate channel:(HCHANNEL)channel;

+ (NSString *)stringForLastError;
+ (NSString *)stringForErrorCode:(int)erro;
+ (NSError *)errorForErrorCode:(int)erro;
+ (NSError *)errorForLastError;

@end

@protocol BASSChannelDelegate <NSObject>
@optional
- (void)channelDidEnd;
- (void)channelDownloadDidFinish;
- (void)channelDeviceDidFail;
- (void)channelDeviceDidChange;
- (void)channelSetSyncDidFail:(NSError*)err;
@end
