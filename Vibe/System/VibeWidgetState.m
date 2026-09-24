//
//  VibeWidgetState.m
//  Vibe
//
//  See VibeWidgetState.h.
//

#import "VibeWidgetState.h"

#import <notify.h>

// TRAP: the two platforms spell the group differently, and each spelling is
// the only one that works there. From macOS 15 a container is granted only to
// an App Store app, a group a provisioning profile authorizes, or a group
// prefixed with the signing team's ID — and an extension that fails is denied
// SILENTLY, which draws an empty widget. The Developer ID build carries no
// profile, so the mac group is team-prefixed; iOS requires the group. form.
// The entitlements files carry the same strings.
#if TARGET_OS_OSX
NSString *const kVibeWidgetAppGroup = @"4UEV752JH4.com.commonwealthrecordings.Vibe";
#else
NSString *const kVibeWidgetAppGroup = @"group.com.commonwealthrecordings.Vibe";
#endif
const char *const kVibeWidgetReadNotification = "com.commonwealthrecordings.Vibe.widget.read";

NSString *const kVibeWidgetThemeDark       = @"dark";
NSString *const kVibeWidgetThemeLight      = @"light";
NSString *const kVibeWidgetThemePlayGlyph  = @"playGlyph";
NSString *const kVibeWidgetThemePauseGlyph = @"pauseGlyph";
NSString *const kVibeWidgetThemeNextGlyph  = @"nextGlyph";
NSString *const kVibeWidgetColorTitle      = @"title";
NSString *const kVibeWidgetColorArtist     = @"artist";
NSString *const kVibeWidgetColorPlayButton = @"playButton";
NSString *const kVibeWidgetColorNextButton = @"nextButton";
NSString *const kVibeWidgetColorBackground = @"background";

static NSString *const kStateFileName = @"state.plist";
// The image files carry their track's key, so the container can hold two
// tracks' sets at once and a plist always names its own.
static NSString *const kArtworkFormat  = @"artwork-%@.jpg";
static NSString *const kPlaceholderDark  = @"placeholder-dark.png";
static NSString *const kPlaceholderLight = @"placeholder-light.png";
static NSString *const kWidgetMark = @"widget-present";

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
static NSString *const kKeyStartPending = @"startPending";
static NSString *const kKeyTheme        = @"theme";

// Bumped when a field's meaning changes. A reader that does not recognize the
// version draws the empty state, which is always safe: the app republishes on
// its next track event anyway.
static const NSInteger kStateVersion = 2;   // 2: trackKey, and the images named by it

@implementation VibeWidgetState

+ (NSURL *)containerURL {
    // Resolved once: the container manager answers over XPC, and every file
    // this class names went back to it.
    static NSURL *container;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        container = [NSFileManager.defaultManager
                containerURLForSecurityApplicationGroupIdentifier:kVibeWidgetAppGroup];
    });
    return container;
}

+ (nullable NSURL *)fileNamed:(NSString *)name {
    NSURL *container = self.containerURL;
    return container ? [container URLByAppendingPathComponent:name] : nil;
}

+ (nullable NSURL *)fileNamed:(NSString *)format trackKey:(nullable NSString *)trackKey {
    return trackKey.length ? [self fileNamed:[NSString stringWithFormat:format, trackKey]] : nil;
}

static NSString *VibeWidgetWaveformName(NSString *trackKey, BOOL played, BOOL light) {
    return [NSString stringWithFormat:@"waveform-%@-%@%@.png", trackKey,
            played ? @"played" : @"unplayed", light ? @"-light" : @""];
}

- (NSURL *)artworkURL {
    return [self.class fileNamed:kArtworkFormat trackKey:self.trackKey];
}

- (NSURL *)waveformURLPlayed:(BOOL)played light:(BOOL)light {
    NSString *key = self.trackKey;
    return key.length ? [self.class fileNamed:VibeWidgetWaveformName(key, played, light)] : nil;
}

+ (NSURL *)placeholderURLForDark:(BOOL)isDark {
    return [self fileNamed:isDark ? kPlaceholderDark : kPlaceholderLight];
}

- (id)copyWithZone:(NSZone *)zone {
    VibeWidgetState *copy = [[VibeWidgetState alloc] init];
    copy.title        = self.title;
    copy.artist       = self.artist;
    copy.hasTrack     = self.hasTrack;
    copy.playing      = self.playing;
    copy.duration     = self.duration;
    copy.trackKey     = self.trackKey;
    copy.position     = self.position;
    copy.positionDate = self.positionDate;
    copy.startPending = self.startPending;
    copy.theme        = self.theme;
    return copy;
}

+ (NSArray<NSURL *> *)imageURLsNotForTrackKeys:(NSArray<NSString *> *)trackKeys {
    NSURL *container = self.containerURL;
    if (!container) {
        return @[];
    }
    NSMutableSet<NSString *> *keep = [NSMutableSet set];
    for (NSString *key in trackKeys) {
        if (key.length) {
            [keep addObject:[NSString stringWithFormat:kArtworkFormat, key]];
            for (int strip = 0; strip < 4; strip++) {
                [keep addObject:VibeWidgetWaveformName(key, strip & 1, strip & 2)];
            }
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

+ (BOOL)widgetMayBePlaced {
    NSURL *mark = [self fileNamed:kWidgetMark];
    return mark && [NSFileManager.defaultManager fileExistsAtPath:mark.path];
}

+ (void)forgetWidget {
    NSURL *mark = [self fileNamed:kWidgetMark];
    if (mark) {
        [NSFileManager.defaultManager removeItemAtURL:mark error:NULL];
    }
}

+ (VibeWidgetState *)loadState {
    // Before the read, not after a successful one: an empty container is still
    // a widget asking, and it is exactly the widget that needs the app to
    // start publishing. The mark is for an app not running to hear the signal.
    NSURL *mark = [self fileNamed:kWidgetMark];
    if (mark && ![NSFileManager.defaultManager fileExistsAtPath:mark.path]) {
        [NSData.data writeToURL:mark atomically:NO];
    }
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
    state.startPending = [plist[kKeyStartPending] boolValue];
    NSDictionary *theme = plist[kKeyTheme];
    state.theme        = [theme isKindOfClass:NSDictionary.class] ? theme : nil;
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
    plist[kKeyStartPending] = @(self.startPending);
    plist[kKeyTheme]        = self.theme;
    return [plist writeToURL:url error:NULL];
}

- (NSTimeInterval)positionAtDate:(NSDate *)date {
    NSTimeInterval elapsed = 0;
    if (self.playing && !self.startPending && self.positionDate) {
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
