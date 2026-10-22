//
//  RepeatMode.h
//  Vibe
//
//  What follows the end of a track or of the playlist. Its own header because
//  Playlist takes it as a model property and may not import a setting. An app
//  keeps its stored identifiers for the modes.
//

#import <Foundation/Foundation.h>

// MPRepeatType's three cases with its raw values, so Now Playing converts by
// cast.
typedef NS_ENUM(NSInteger, VibeRepeatMode) {
    // The end of the playlist parks. The default.
    VibeRepeatModeOff = 0,
    // A track that plays out replays. Next and Previous behave as under Off.
    VibeRepeatModeOne = 1,
    // The end of the playlist continues from its start, or into a fresh
    // shuffled order.
    VibeRepeatModeAll = 2,
};
