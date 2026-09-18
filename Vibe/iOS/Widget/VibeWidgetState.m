//
//  VibeWidgetState.m
//  Vibe (iOS)
//
//  See VibeWidgetState.h.
//

#import "VibeWidgetState.h"

#import <notify.h>

NSString *const kVibeWidgetAppGroup = @"group.com.commonwealthrecordings.Vibe";
const char *const kVibeWidgetReadNotification = "com.commonwealthrecordings.Vibe.widget.read";

static NSString *const kStateFileName = @"state.plist";
// The image files carry their track's key, so the container can hold two
// tracks' sets at once and a plist always names its own.
static NSString *const kArtworkFormat  = @"artwork-%@.jpg";
static NSString *const kPlayedFormat   = @"waveform-%@-played.png";
static NSString *const kUnplayedFormat = @"waveform-%@-unplayed.png";

// Plist keys. Spelled once: a typo on one side of the app/extension boundary
// reads as an absent field, which draws an empty widget rather than failing.
static NSString *const kKeyVersion      = @"version";
static NSString *const kKeyTitle        = @"title";
static NSString *const kKeyArtist       = @"artist";
static NSString *const kKeyTrackKey     = @"trackKey";
static NSString *const kKeyHasTrack     = @"hasTrack";
static NSString *const kKeyPlaying      = @"playing";
static NSString *const kKeyDuration     = @"duration";
static NSString *const kKeyPosition     = @"position";
static NSString *const kKeyPositionDate = @"positionDate";

// Bumped when a field's meaning changes. A reader that does not recognize the
// version draws the empty state, which is always safe: the app republishes on
// its next track event anyway.
static const NSInteger kStateVersion = 2;   // 2: trackKey, and the images named by it

@implementation VibeWidgetState

+ (NSURL *)containerURL {
    return [NSFileManager.defaultManager
            containerURLForSecurityApplicationGroupIdentifier:kVibeWidgetAppGroup];
}

+ (nullable NSURL *)fileNamed:(NSString *)name {
    NSURL *container = self.containerURL;
    return container ? [container URLByAppendingPathComponent:name] : nil;
}

+ (nullable NSURL *)fileNamed:(NSString *)format trackKey:(nullable NSString *)trackKey {
    return trackKey.length ? [self fileNamed:[NSString stringWithFormat:format, trackKey]] : nil;
}

+ (NSURL *)artworkURLForTrackKey:(NSString *)key          { return [self fileNamed:kArtworkFormat trackKey:key]; }
+ (NSURL *)waveformPlayedURLForTrackKey:(NSString *)key   { return [self fileNamed:kPlayedFormat trackKey:key]; }
+ (NSURL *)waveformUnplayedURLForTrackKey:(NSString *)key { return [self fileNamed:kUnplayedFormat trackKey:key]; }
- (NSURL *)artworkURL          { return [self.class artworkURLForTrackKey:self.trackKey]; }
- (NSURL *)waveformPlayedURL   { return [self.class waveformPlayedURLForTrackKey:self.trackKey]; }
- (NSURL *)waveformUnplayedURL { return [self.class waveformUnplayedURLForTrackKey:self.trackKey]; }

+ (NSArray<NSURL *> *)imageURLsNotForTrackKeys:(NSArray<NSString *> *)trackKeys {
    NSURL *container = self.containerURL;
    if (!container) {
        return @[];
    }
    NSMutableSet<NSString *> *keep = [NSMutableSet set];
    for (NSString *key in trackKeys) {
        if (key.length) {
            [keep addObject:[NSString stringWithFormat:kArtworkFormat, key]];
            [keep addObject:[NSString stringWithFormat:kPlayedFormat, key]];
            [keep addObject:[NSString stringWithFormat:kUnplayedFormat, key]];
        }
    }
    NSMutableArray<NSURL *> *stale = [NSMutableArray array];
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:container includingPropertiesForKeys:nil
                             options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    for (NSURL *url in contents) {
        NSString *name = url.lastPathComponent;
        BOOL image = [name hasPrefix:@"artwork-"] || [name hasPrefix:@"waveform-"];
        if (image && ![keep containsObject:name]) {
            [stale addObject:url];
        }
    }
    return stale;
}

+ (VibeWidgetState *)loadState {
    // Before the read, not after a successful one: an empty container is still
    // a widget asking, and it is exactly the widget that needs the app to
    // start publishing.
    notify_post(kVibeWidgetReadNotification);
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
    state.trackKey     = plist[kKeyTrackKey];
    state.hasTrack     = [plist[kKeyHasTrack] boolValue];
    state.playing      = [plist[kKeyPlaying] boolValue];
    state.duration     = [plist[kKeyDuration] doubleValue];
    state.position     = [plist[kKeyPosition] doubleValue];
    state.positionDate = plist[kKeyPositionDate];
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
    plist[kKeyTrackKey]     = self.trackKey;
    plist[kKeyHasTrack]     = @(self.hasTrack);
    plist[kKeyPlaying]      = @(self.playing);
    plist[kKeyDuration]     = @(self.duration);
    plist[kKeyPosition]     = @(self.position);
    plist[kKeyPositionDate] = self.positionDate;
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
