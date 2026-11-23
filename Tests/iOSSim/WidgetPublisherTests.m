// The publisher's half of the app group's file layout: the key that names a
// track's images and rides in every seek button. It is spelled from the
// item alone, so a widget placed before an update keeps finding its files.

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "NSURL+Hash.h"
#import "WidgetPublisher.h"

@interface WidgetPublisherTests : XCTestCase
@end

@implementation WidgetPublisherTests

- (void)testATrackKeyIsItsFilesPathKeyAndACueRowAddsItsWindow {
    NSURL *url = [NSURL fileURLWithPath:@"/Music/mix.flac"];
    NSString *pathKey = url.pathKey;
    XCTAssertNotNil(pathKey);

    XCTAssertEqualObjects([WidgetPublisher trackKeyForTrack:[AudioTrack withURL:url]], pathKey);
    AudioTrack *row = [[AudioTrack alloc] initWithURL:url cueStart:4500 cueEnd:9000 title:@"Two"
                                            performer:nil sheet:nil trackNumber:2];
    XCTAssertEqualObjects([WidgetPublisher trackKeyForTrack:row],
                          [pathKey stringByAppendingString:@"#4500-9000"]);
    XCTAssertNil([WidgetPublisher trackKeyForTrack:nil]);
}

@end
