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

BOOL VibeShowsRemainingTime(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kShowRemainingTimeKey];
}

void VibeSetShowsRemainingTime(BOOL remaining) {
    [NSUserDefaults.standardUserDefaults setBool:remaining forKey:kShowRemainingTimeKey];
}

BOOL VibeShowsFileInfo(void) {
    // Defaults ON: absence is tested rather than registered in AppSettings.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:kShowFileInfoKey] == nil
            || [defaults boolForKey:kShowFileInfoKey];
}

void VibeSetShowsFileInfo(BOOL show) {
    [NSUserDefaults.standardUserDefaults setBool:show forKey:kShowFileInfoKey];
}
