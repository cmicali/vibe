// The publisher's half of the app group's file layout: the key that names a
// track's images and rides in every seek button. It is spelled from the
// item alone, so a widget placed before an update keeps finding its files.

#import <XCTest/XCTest.h>

#import "NSURL+Hash.h"
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

@interface WidgetPublisherTests : XCTestCase
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

@end
