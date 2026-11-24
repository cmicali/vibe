// vibe-libs' widget publisher (system/Widget), where it needs UIKit and the
// app's launch, which names the app group. A publisher with a bake queued is
// still freed. The track key's own test is vibe-libs'.

#import <XCTest/XCTest.h>

#import "AppSettings.h"
#import "AudioWaveform.h"
#import "IOSSimTestCase.h"
#import "VibeWidgetState.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme+Settings.h"
#import "WidgetPublisher.h"

// A track as the widget reads it, with nothing behind it.
@interface WidgetTestTrack : NSObject <VibeWidgetTrack>
@property (copy) NSURL *url;
@property NSUInteger cueStart;
@property NSUInteger cueEnd;
@end

@implementation WidgetTestTrack
- (NSString *)sourceKey { return self.url.path; }
- (NSString *)cacheKey { return nil; }
- (NSString *)displayTitle { return @"Song"; }
- (NSString *)displayArtist { return nil; }
- (UIImage *)cachedArt { return nil; }
@end

// Complete, so the publisher bakes it.
static CodableAudioWaveform *CompleteWaveform(void) {
    auto waveform = std::make_unique<AudioWaveform>(64, false, 44100);
    for (size_t i = 0; i < 1024; i++) {
        float level = 0.3f + 0.6f * (float)fabs(sin((double)i / 9.0));
        waveform->appendBin(-level, level, level * level * 64, nullptr, 64);
    }
    waveform->markComplete();
    return [[CodableAudioWaveform alloc] initWithWaveform:std::move(waveform)];
}

// The app group's files by name. A test publisher writes the host app's real
// container, which the piece resolves once per process, so the test puts back
// what it found.
static NSDictionary<NSString *, NSData *> *ContainerFiles(void) {
    NSMutableDictionary<NSString *, NSData *> *files = [NSMutableDictionary dictionary];
    NSURL *container = VibeWidgetState.containerURL;
    if (!container) {
        return files;
    }
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:container
            includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    for (NSURL *url in contents) {
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data) {
            files[url.lastPathComponent] = data;
        }
    }
    return files;
}

static void RestoreContainerFiles(NSDictionary<NSString *, NSData *> *files) {
    NSURL *container = VibeWidgetState.containerURL;
    if (!container) {
        return;
    }
    for (NSString *name in ContainerFiles()) {
        if (!files[name]) {
            [NSFileManager.defaultManager removeItemAtURL:[container URLByAppendingPathComponent:name] error:NULL];
        }
    }
    [files enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSData *data, BOOL *stop) {
        [data writeToURL:[container URLByAppendingPathComponent:name] atomically:YES];
    }];
}

@interface WidgetPublisherTests : IOSSimTestCase
@end

@implementation WidgetPublisherTests

// A queued bake once held the publisher through a block the publisher kept,
// so a publisher that had baked was never freed.
- (void)testAPublisherWithABakeQueuedIsFreed {
    NSDictionary<NSString *, NSData *> *found = ContainerFiles();
    __weak WidgetPublisher *weakPublisher = nil;
    WidgetTestTrack *track = [WidgetTestTrack new];
    track.url = [NSURL fileURLWithPath:@"/Music/song.flac"];
    @autoreleasepool {
        WidgetPublisher *publisher = [[WidgetPublisher alloc]
                initWithThemeProvider:^WaveformTheme *(BOOL isDark, UIColor *artworkColor) {
                    return [WaveformTheme themeForSettings:AppSettings.sharedInstance widget:YES isDark:isDark
                                              artworkColor:artworkColor];
                }
                      reloadTimelines:^{}
                          queryPlaced:^(void (^completion)(BOOL, NSError *)) { completion(YES, nil); }];
        weakPublisher = publisher;
        XCTAssertTrue([self eventually:^BOOL { return publisher.widgetPlaced; }]);
        [publisher updateWaveformStyle:WaveformRendererRegistry.styleIdentifiers.firstObject
                              centered:NO drawsPlayheadLine:NO];
        [publisher updateWithTrack:track position:0 duration:100 playing:NO startPending:NO];
        [publisher offerWaveform:CompleteWaveform() forTrack:track];
    }
    // Freed only once its queue has run every write, since each holds it.
    XCTAssertTrue([self eventually:^BOOL { return weakPublisher == nil; }],
                  @"the queued bake keeps the publisher");
    RestoreContainerFiles(found);
    XCTAssertEqualObjects(ContainerFiles(), found, @"the app group as the test found it");
}

@end
