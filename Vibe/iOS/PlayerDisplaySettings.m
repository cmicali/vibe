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
static NSString *const kWidgetWaveformStyleKey = @"VibeiOSWidgetWaveformStyle";

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

NSString *VibeWidgetWaveformStyle(void) {
    // Absent OR empty reads as "match the app": the picker writes nil for that
    // row, and an empty string from a hand-edited defaults plist should not
    // resolve to some arbitrary registered style.
    NSString *identifier = [NSUserDefaults.standardUserDefaults
            stringForKey:kWidgetWaveformStyleKey];
    return identifier.length ? identifier : nil;
}

void VibeSetWidgetWaveformStyle(NSString *identifier) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (identifier.length) {
        [defaults setObject:identifier forKey:kWidgetWaveformStyleKey];
    }
    else {
        [defaults removeObjectForKey:kWidgetWaveformStyleKey];
    }
}
