//
//  PlayerDisplaySettings.m
//  Vibe (iOS)
//

#import "PlayerDisplaySettings.h"

NSNotificationName const VibeDisplaySettingsDidChangeNotification =
        @"VibeDisplaySettingsDidChange";

void VibeNotifyDisplaySettingsChanged(void) {
    [NSNotificationCenter.defaultCenter
            postNotificationName:VibeDisplaySettingsDidChangeNotification object:nil];
}
