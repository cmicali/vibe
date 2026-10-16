//
//  ArtworkImageViewTests.m
//  VibeTests
//
//  The art card's gates and what it draws, and the drag's label component,
//  with no window server. A dragging session itself needs one, so the drag
//  start is left to the vibe-debug skill.
//

#import <XCTest/XCTest.h>

#import "DrawnViewTestSupport.h"
#import "ArtworkImageView.h"
#import "NSDraggingImageComponent+Util.h"

static NSImage *SolidImage(NSColor *color) {
    return [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [color setFill];
        NSRectFill(rect);
        return YES;
    }];
}

@interface ArtworkImageViewTests : XCTestCase
@end

@implementation ArtworkImageViewTests

- (void)testWithNoFileTheCardMovesTheWindow {
    ArtworkImageView *view = [[ArtworkImageView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    XCTAssertTrue(view.mouseDownCanMoveWindow);
    XCTAssertFalse([view acceptsFirstMouse:nil]);
    view.fileURL = [NSURL fileURLWithPath:@"/tmp/a.flac"];
    XCTAssertFalse(view.mouseDownCanMoveWindow, @"a track's card drags the file");
    XCTAssertTrue([view acceptsFirstMouse:nil]);
}

- (void)testItDrawsItsArtAndNothingWithout {
    ArtworkImageView *view = [[ArtworkImageView alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
    view.imageScaling = NSImageScaleAxesIndependently;
    XCTAssertTrue(VibeBitmapIsBlank(VibeRenderView(view)));
    view.image = SolidImage(NSColor.redColor);
    NSColor *center = VibePixel(VibeRenderView(view), NO, 16, 16);
    XCTAssertGreaterThan(center.redComponent, 0.9);
    XCTAssertGreaterThan(center.alphaComponent, 0.9);
}

- (void)testTheDragLabelSitsCenteredBelowTheIcon {
    CGRect icon = CGRectMake(10, 40, 48, 48);
    NSDraggingImageComponent *label = [NSDraggingImageComponent labelWithString:@"Song.flac" imageRect:icon];
    XCTAssertEqualObjects(label.key, NSDraggingImageComponentLabelKey);
    XCTAssertEqualWithAccuracy(NSMidX(label.frame), NSMidX(icon), 0.5);
    XCTAssertEqualWithAccuracy(NSMaxY(label.frame), NSMinY(icon) - 8, 1e-9);
    NSImage *contents = label.contents;
    XCTAssertTrue([contents isKindOfClass:NSImage.class]);
    XCTAssertEqualObjects(NSStringFromSize(contents.size), NSStringFromSize(label.frame.size));
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:contents.TIFFRepresentation];
    XCTAssertFalse(VibeBitmapIsBlank(rep), @"the label is drawn");
}

@end
