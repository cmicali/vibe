//
//  NSImageUtilTests.m
//  VibeTests
//
//  Pins squareCroppedImage: the centered-square crop that keeps a non-square
//  cover from letterboxing in the square frames that display it.
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "NSImage+Util.h"
#import "PlatformImage.h"

@interface NSImageUtilTests : XCTestCase
@end

@implementation NSImageUtilTests

// A test cover: the largest centered square is magenta, the bands the crop
// must discard are green.
- (NSImage *)coverWithSize:(NSSize)size {
    return [NSImage imageWithSize:size drawnBy:^{
        CGFloat side = MIN(size.width, size.height);
        [[NSColor greenColor] setFill];
        NSRectFill(NSMakeRect(0, 0, size.width, size.height));
        [[NSColor magentaColor] setFill];
        NSRectFill(NSMakeRect((size.width - side) / 2, (size.height - side) / 2, side, side));
    }];
}

- (NSColor *)colorAt:(NSPoint)point in:(NSImage *)image {
    NSBitmapImageRep *rep = (NSBitmapImageRep *)image.representations.firstObject;
    XCTAssertTrue([rep isKindOfClass:NSBitmapImageRep.class]);
    return [[rep colorAtX:(NSInteger)point.x y:(NSInteger)point.y]
            colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}

- (void)assertMagenta:(NSColor *)color at:(NSString *)where {
    XCTAssertGreaterThan(color.redComponent, 0.5, @"%@ red", where);
    XCTAssertLessThan(color.greenComponent, 0.5, @"%@ green", where);
    XCTAssertGreaterThan(color.blueComponent, 0.5, @"%@ blue", where);
}

- (void)testWideImageCropsToCenteredSquare {
    NSImage *cropped = [[self coverWithSize:NSMakeSize(400, 100)] squareCroppedImage];
    XCTAssertEqualWithAccuracy(cropped.size.width, 100, 0.5);
    XCTAssertEqualWithAccuracy(cropped.size.height, 100, 0.5);
    // Every corner comes from the discarded-band-free center square.
    [self assertMagenta:[self colorAt:NSMakePoint(1, 1) in:cropped] at:@"bottom-left"];
    [self assertMagenta:[self colorAt:NSMakePoint(98, 98) in:cropped] at:@"top-right"];
    [self assertMagenta:[self colorAt:NSMakePoint(50, 50) in:cropped] at:@"center"];
}

- (void)testTallImageCropsToCenteredSquare {
    NSImage *cropped = [[self coverWithSize:NSMakeSize(100, 400)] squareCroppedImage];
    XCTAssertEqualWithAccuracy(cropped.size.width, 100, 0.5);
    XCTAssertEqualWithAccuracy(cropped.size.height, 100, 0.5);
    [self assertMagenta:[self colorAt:NSMakePoint(1, 1) in:cropped] at:@"bottom-left"];
    [self assertMagenta:[self colorAt:NSMakePoint(98, 98) in:cropped] at:@"top-right"];
}

// The common case must not pay for a re-render.
- (void)testSquareImageIsReturnedUnchanged {
    NSImage *square = [self coverWithSize:NSMakeSize(200, 200)];
    XCTAssertEqual([square squareCroppedImage], square);
}

- (void)testZeroSizedImageReturnsNil {
    XCTAssertNil([[[NSImage alloc] initWithSize:NSZeroSize] squareCroppedImage]);
}

- (void)testSameSizeResizeCreatesAPrivateRaster {
    NSImage *source = [self coverWithSize:NSMakeSize(128, 128)];
    NSImage *raster = [source resizedImage:source.size];

    XCTAssertNotNil(raster);
    XCTAssertNotEqual(raster, source);
    XCTAssertTrue([raster.representations.firstObject isKindOfClass:NSBitmapImageRep.class]);
    XCTAssertNotEqual(raster.representations.firstObject, source.representations.firstObject);
}

// The transport buttons read the art under them: a cover dark along its
// bottom asks for the light-on-dark colors, one light along its bottom for
// the dark-on-light ones, whatever the rest of the picture holds.
- (void)testLowerBandDarknessFollowsTheBottomOfTheImage {
    NSImage *(^split)(NSColor *, NSColor *) = ^(NSColor *top, NSColor *bottom) {
        return [NSImage imageWithSize:NSMakeSize(64, 64) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            [bottom setFill];
            NSRectFill(NSMakeRect(0, 0, 64, 32));
            [top setFill];
            NSRectFill(NSMakeRect(0, 32, 64, 32));
            return YES;
        }];
    };
    XCTAssertTrue(VibeImageLowerBandIsDark(split(NSColor.whiteColor, NSColor.blackColor), 1.0 / 3));
    XCTAssertFalse(VibeImageLowerBandIsDark(split(NSColor.blackColor, NSColor.whiteColor), 1.0 / 3));
    XCTAssertTrue(VibeImageLowerBandIsDark(split(NSColor.whiteColor, [NSColor colorWithWhite:0.3 alpha:1]), 0.5));
    XCTAssertTrue(VibeImageLowerBandIsDark(nil, 0.5), @"unrasterizable reads as dark");
}

@end
