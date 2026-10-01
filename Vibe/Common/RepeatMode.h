//
//  RepeatMode.h
//  Vibe
//
//  What follows the end of a track or of the playlist. Its own header because
//  Playlist takes it as a model property and may not import a setting.
//

#import <Foundation/Foundation.h>

// MPRepeatType's three cases, in the order a tap or ⌘R cycles them.
typedef NS_ENUM(NSInteger, VibeRepeatMode) {
    // The end of the playlist parks. The default.
    VibeRepeatModeOff = 0,
    // The end of the playlist continues from its start, or into a fresh
    // shuffled order.
    VibeRepeatModeAll,
    // A track that plays out replays. Next and Previous behave as under Off.
    VibeRepeatModeOne,
};

// Stable stored identifiers, never display names.
#define SETTINGS_VALUE_REPEAT_MODE_OFF      @"off"
#define SETTINGS_VALUE_REPEAT_MODE_ALL      @"all"
#define SETTINGS_VALUE_REPEAT_MODE_ONE      @"one"
