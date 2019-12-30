//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AppSettings.h"

#define SETTING_AUDIO_PLAYER_CURRENT_DEVICE     @"AudioPlayer.currentDevice"

@implementation AppSettings {

}

+ (AppSettings*)sharedInstance {
    static AppSettings *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AppSettings alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {
    NSDictionary *appDefaults = @{
            SETTING_AUDIO_PLAYER_CURRENT_DEVICE : @(-1)
    };
    [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
}

- (NSInteger) audioPlayerCurrentDevice {
    return [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_AUDIO_PLAYER_CURRENT_DEVICE];
}

-(void) setAudioPlayerCurrentDevice:(NSInteger)deviceIndex {
    [[NSUserDefaults standardUserDefaults] setInteger:deviceIndex forKey:SETTING_AUDIO_PLAYER_CURRENT_DEVICE];
}

@end
