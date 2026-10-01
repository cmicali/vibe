//
//  RepeatMode.h
//  Vibe
//
//  What follows the end of a track or of the playlist. Its own header because
//  Playlist takes it as a model property and may not import a setting.
//

#import <Foundation/Foundation.h>

// MPRepeatType's three cases with its raw values, so Now Playing converts by
// cast. The order a tap or ⌘R cycles them is VibeRepeatModeAfter's.
typedef NS_ENUM(NSInteger, VibeRepeatMode) {
    // The end of the playlist parks. The default.
    VibeRepeatModeOff = 0,
    // A track that plays out replays. Next and Previous behave as under Off.
    VibeRepeatModeOne = 1,
    // The end of the playlist continues from its start, or into a fresh
    // shuffled order.
    VibeRepeatModeAll = 2,
};

// Stable stored identifiers, never display names.
#define SETTINGS_VALUE_REPEAT_MODE_OFF      @"off"
#define SETTINGS_VALUE_REPEAT_MODE_ALL      @"all"
#define SETTINGS_VALUE_REPEAT_MODE_ONE      @"one"
