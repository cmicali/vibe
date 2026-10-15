
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

// The transport buttons pick their colors from the art under them, whatever
// the rest of the picture holds.
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
    XCTAssertTrue(VibeImageLowerBandIsDark(split(NSColor.whiteColor, NSColor.blackColor), 1.0 / 3, NO));
    XCTAssertFalse(VibeImageLowerBandIsDark(split(NSColor.blackColor, NSColor.whiteColor), 1.0 / 3, YES));
    XCTAssertTrue(VibeImageLowerBandIsDark(split(NSColor.whiteColor, [NSColor colorWithWhite:0.3 alpha:1]), 0.5, NO));
    XCTAssertTrue(VibeImageLowerBandIsDark(nil, 0.5, YES), @"unrasterizable reads as the backdrop");
    XCTAssertFalse(VibeImageLowerBandIsDark(nil, 0.5, NO));
    NSImage *empty = [[NSImage alloc] initWithSize:NSMakeSize(64, 64)];
    XCTAssertFalse(VibeImageLowerBandIsDark(empty, 0.5, NO), @"a transparent band shows the backdrop");
    XCTAssertTrue(VibeImageLowerBandIsDark(empty, 0.5, YES));
}

#pragma mark - dominantColor

// Bands left to right, each filling its share of the width.
- (NSImage *)bands:(NSArray<NSColor *> *)colors shares:(NSArray<NSNumber *> *)shares {
    NSSize size = NSMakeSize(64, 64);
    return [NSImage imageWithSize:size drawnBy:^{
        CGFloat x = 0;
        for (NSUInteger i = 0; i < colors.count; i++) {
            CGFloat width = size.width * shares[i].doubleValue;
            [colors[i] setFill];
            NSRectFill(NSMakeRect(x, 0, width, size.height));
            x += width;
        }
    }];
}

// The art tint and the album_art waveform theme: vivid pixels vote by hue, so
// the biggest vivid band wins over a larger gray area and a smaller other hue.
- (void)testDominantColorIsTheBiggestVividHue {
    NSColor *gray = [NSColor colorWithSRGBRed:0.5 green:0.5 blue:0.5 alpha:1];
    NSColor *blue = [NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1];
    NSColor *red = [NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1];
    NSColor *color = [[self bands:@[gray, blue, red] shares:@[@0.5, @0.3, @0.2]] dominantColor];
    XCTAssertNotNil(color);
    XCTAssertGreaterThan(color.blueComponent, 0.8);
    XCTAssertLessThan(color.redComponent, 0.2);
    XCTAssertLessThan(color.greenComponent, 0.2);
}

// With nothing vivid, the answer is the plain average, so a gray cover reads as
// gray and the theme falls back to Mono.
- (void)testDominantColorOfGrayArtIsItsAverage {
    NSColor *dark = [NSColor colorWithSRGBRed:0.2 green:0.2 blue:0.2 alpha:1];
    NSColor *light = [NSColor colorWithSRGBRed:0.6 green:0.6 blue:0.6 alpha:1];
    NSColor *color = [[self bands:@[dark, light] shares:@[@0.5, @0.5]] dominantColor];
    XCTAssertNotNil(color);
    XCTAssertEqualWithAccuracy(color.redComponent, 0.4, 0.03);
    XCTAssertEqualWithAccuracy(color.greenComponent, color.redComponent, 0.01);
    XCTAssertEqualWithAccuracy(color.blueComponent, color.redComponent, 0.01);
    XCTAssertNil(VibeDominantColorOfImage(nil));
}

@end
