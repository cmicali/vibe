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

static NSString *const kShowRemainingTimeKey = @"VibeiOSShowRemainingTime";
static NSString *const kShowFileInfoKey      = @"VibeiOSShowFileInfo";
static NSString *const kShowShuffleRepeatKey = @"VibeiOSShowShuffleRepeat";

// Absence is tested rather than registered in AppSettings, which these keys
// are not.
static BOOL VibeBoolDefaultingOn(NSString *key) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:key] == nil || [defaults boolForKey:key];
}

BOOL VibeShowsRemainingTime(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kShowRemainingTimeKey];
}

void VibeSetShowsRemainingTime(BOOL remaining) {
    [NSUserDefaults.standardUserDefaults setBool:remaining forKey:kShowRemainingTimeKey];
}

BOOL VibeShowsFileInfo(void) {
    return VibeBoolDefaultingOn(kShowFileInfoKey);
}

void VibeSetShowsFileInfo(BOOL show) {
    [NSUserDefaults.standardUserDefaults setBool:show forKey:kShowFileInfoKey];
}

BOOL VibeShowsShuffleRepeat(void) {
    return VibeBoolDefaultingOn(kShowShuffleRepeatKey);
}

void VibeSetShowsShuffleRepeat(BOOL show) {
    [NSUserDefaults.standardUserDefaults setBool:show forKey:kShowShuffleRepeatKey];
}
