//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AppSettings.h"

#define SETTING_HAS_LAUNCHED                    @"Settings.hasLaunched"
#define SETTING_WINDOW_X                        @"Window.x"
#define SETTING_WINDOW_Y                        @"Window.y"
#define SETTING_WINDOW_IS_PLAYLIST_SHOWN        @"Window.isPlaylistShown"
#define SETTING_AUDIO_PLAYER_CURRENT_DEVICE     @"AudioPlayer.currentDevice"

@implementation AppSettings {
    BOOL _firstLaunch;
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
        [self registerDefaults];
    }
    return self;
}

- (void)registerDefaults {
    _firstLaunch = NO;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:SETTING_HAS_LAUNCHED]) {
        _firstLaunch = YES;
    }
    NSDictionary *appDefaults = @{
            SETTING_AUDIO_PLAYER_CURRENT_DEVICE : @(-1)
    };
    [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:SETTING_HAS_LAUNCHED];
}

- (NSInteger) audioPlayerCurrentDevice {
    return [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_AUDIO_PLAYER_CURRENT_DEVICE];
}

-(void) setAudioPlayerCurrentDevice:(NSInteger)deviceIndex {
    [[NSUserDefaults standardUserDefaults] setInteger:deviceIndex forKey:SETTING_AUDIO_PLAYER_CURRENT_DEVICE];
}

- (void)applicationDidFinishLaunching {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"NSQuitAlwaysKeepsWindows"];
}

- (BOOL)isFirstLaunch {
    return _firstLaunch;
}

- (CGPoint)windowPosition {
    CGPoint p;
    p.x = [[NSUserDefaults standardUserDefaults] doubleForKey:SETTING_WINDOW_X];
    p.y = [[NSUserDefaults standardUserDefaults] doubleForKey:SETTING_WINDOW_Y];
    return p;
}

- (void)setWindowPosition:(CGPoint)position {
    [[NSUserDefaults standardUserDefaults] setDouble:position.x forKey:SETTING_WINDOW_X];
    [[NSUserDefaults standardUserDefaults] setDouble:position.y forKey:SETTING_WINDOW_Y];
}

- (BOOL)isPlaylistShown {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_WINDOW_IS_PLAYLIST_SHOWN];
}

- (void)setIsPlaylistShown:(BOOL)isPlaylistShown {
    [[NSUserDefaults standardUserDefaults] setBool:isPlaylistShown forKey:SETTING_WINDOW_IS_PLAYLIST_SHOWN];
}

@end
