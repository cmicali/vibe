//
//  PlayerDisplaySettings.m
//  Vibe (iOS)
//
//  See PlayerDisplaySettings.h.
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

BOOL VibeShowsRemainingTime(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kShowRemainingTimeKey];
}

void VibeSetShowsRemainingTime(BOOL remaining) {
    [NSUserDefaults.standardUserDefaults setBool:remaining forKey:kShowRemainingTimeKey];
}

BOOL VibeShowsFileInfo(void) {
    // A key never written reads back as NO, and this one defaults to ON — so
    // the absence is tested rather than registered, which keeps the key iOS's
    // own instead of putting it in AppSettings' defaults dictionary.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:kShowFileInfoKey] == nil
            || [defaults boolForKey:kShowFileInfoKey];
}

void VibeSetShowsFileInfo(BOOL show) {
    [NSUserDefaults.standardUserDefaults setBool:show forKey:kShowFileInfoKey];
}
