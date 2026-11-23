// vibe-libs' widget publisher (system/Widget), where it needs UIKit and the
// app's launch. The key that names a track's images is spelled from the item
// alone, so a widget placed before an update keeps finding its files. A
// publisher with a bake queued is still freed.

#import <XCTest/XCTest.h>

#import "AppSettings.h"
#import "AudioWaveform.h"
#import "IOSSimTestCase.h"
#import "NSURL+Hash.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme+Settings.h"
#import "WidgetPublisher.h"

// Only what the key reads, so the test moves with the publisher.
@interface WidgetKeyItem : NSObject <VibePlayableItem>
@property (copy) NSURL *url;
@property NSUInteger cueStart;
@property NSUInteger cueEnd;
@end

@implementation WidgetKeyItem
- (NSString *)sourceKey { return self.url.path; }
- (NSString *)cacheKey { return nil; }
@end

// A track as the widget reads it, with nothing behind it.
@interface WidgetTestTrack : WidgetKeyItem <VibeWidgetTrack>
@end

@implementation WidgetTestTrack
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

@interface WidgetPublisherTests : IOSSimTestCase
@end

@implementation WidgetPublisherTests

- (void)testATrackKeyIsItsFilesPathKeyAndACueRowAddsItsWindow {
    WidgetKeyItem *item = [WidgetKeyItem new];
    item.url = [NSURL fileURLWithPath:@"/Music/mix.flac"];
    NSString *pathKey = item.url.pathKey;
    XCTAssertNotNil(pathKey);
    XCTAssertEqualObjects([WidgetPublisher trackKeyForTrack:item], pathKey);

    item.cueStart = 4500;
    item.cueEnd = 9000;
    XCTAssertEqualObjects([WidgetPublisher trackKeyForTrack:item],
                          [pathKey stringByAppendingString:@"#4500-9000"]);
    XCTAssertNil([WidgetPublisher trackKeyForTrack:nil]);
}

// A queued bake once held the publisher through a block the publisher kept,
// so a publisher that had baked was never freed. The app group is the app's,
// set at launch.
- (void)testAPublisherWithABakeQueuedIsFreed {
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
    XCTAssertTrue([self eventually:^BOOL { return weakPublisher == nil; }],
                  @"the queued bake keeps the publisher");
}

@end
