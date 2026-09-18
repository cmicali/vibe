//
//  VibeWidgetState.m
//  Vibe (iOS)
//
//  See VibeWidgetState.h.
//

#import "VibeWidgetState.h"

NSString *const kVibeWidgetAppGroup = @"group.com.commonwealthrecordings.Vibe";

static NSString *const kStateFileName    = @"state.plist";
static NSString *const kArtworkFileName  = @"artwork.jpg";
static NSString *const kPlayedFileName   = @"waveform-played.png";
static NSString *const kUnplayedFileName = @"waveform-unplayed.png";

// Plist keys. Spelled once: a typo on one side of the app/extension boundary
// reads as an absent field, which draws an empty widget rather than failing.
static NSString *const kKeyVersion      = @"version";
static NSString *const kKeyTitle        = @"title";
static NSString *const kKeyArtist       = @"artist";
static NSString *const kKeyHasTrack     = @"hasTrack";
static NSString *const kKeyTrackKey     = @"trackKey";
static NSString *const kKeyPlaying      = @"playing";
static NSString *const kKeyDuration     = @"duration";
static NSString *const kKeyPosition     = @"position";
static NSString *const kKeyPositionDate = @"positionDate";
static NSString *const kKeyGeneration   = @"generation";

// Bumped when a field's meaning changes. A reader that does not recognize the
// version draws the empty state, which is always safe: the app republishes on
// its next track event anyway.
static const NSInteger kStateVersion = 1;

@implementation VibeWidgetState

+ (NSURL *)containerURL {
    return [NSFileManager.defaultManager
            containerURLForSecurityApplicationGroupIdentifier:kVibeWidgetAppGroup];
}

+ (nullable NSURL *)fileNamed:(NSString *)name {
    NSURL *container = self.containerURL;
    return container ? [container URLByAppendingPathComponent:name] : nil;
}

+ (NSURL *)artworkURL          { return [self fileNamed:kArtworkFileName]; }
+ (NSURL *)waveformPlayedURL   { return [self fileNamed:kPlayedFileName]; }
+ (NSURL *)waveformUnplayedURL { return [self fileNamed:kUnplayedFileName]; }

+ (VibeWidgetState *)loadState {
    NSURL *url = [self fileNamed:kStateFileName];
    if (!url) {
        return nil;
    }
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfURL:url error:NULL];
    if (![plist isKindOfClass:NSDictionary.class]
            || [plist[kKeyVersion] integerValue] != kStateVersion) {
        return nil;
    }
    VibeWidgetState *state = [[VibeWidgetState alloc] init];
    state.title        = plist[kKeyTitle];
    state.artist       = plist[kKeyArtist];
    state.hasTrack     = [plist[kKeyHasTrack] boolValue];
    state.trackKey     = plist[kKeyTrackKey];
    state.playing      = [plist[kKeyPlaying] boolValue];
    state.duration     = [plist[kKeyDuration] doubleValue];
    state.position     = [plist[kKeyPosition] doubleValue];
    state.positionDate = plist[kKeyPositionDate];
    state.generation   = [plist[kKeyGeneration] integerValue];
    return state;
}

- (BOOL)save {
    NSURL *url = [VibeWidgetState fileNamed:kStateFileName];
    if (!url) {
        return NO;
    }
    NSMutableDictionary *plist = [NSMutableDictionary dictionary];
    plist[kKeyVersion]      = @(kStateVersion);
    plist[kKeyTitle]        = self.title;
    plist[kKeyArtist]       = self.artist;
    plist[kKeyHasTrack]     = @(self.hasTrack);
    plist[kKeyTrackKey]     = self.trackKey;
    plist[kKeyPlaying]      = @(self.playing);
    plist[kKeyDuration]     = @(self.duration);
    plist[kKeyPosition]     = @(self.position);
    plist[kKeyPositionDate] = self.positionDate;
    plist[kKeyGeneration]   = @(self.generation);
    return [plist writeToURL:url error:NULL];
}

- (NSTimeInterval)positionAtDate:(NSDate *)date {
    NSTimeInterval elapsed = 0;
    if (self.playing && self.positionDate) {
        elapsed = MAX(0, [date timeIntervalSinceDate:self.positionDate]);
    }
    NSTimeInterval position = self.position + elapsed;
    if (self.duration > 0) {
        position = MIN(position, self.duration);
    }
    return MAX(0, position);
}

- (double)progressAtDate:(NSDate *)date {
    if (self.duration <= 0) {
        return 0;
    }
    return [self positionAtDate:date] / self.duration;
}

@end
