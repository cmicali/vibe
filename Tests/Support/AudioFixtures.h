//
//  AudioFixtures.h
//  VibeTests, VibeAudioTests
//
//  Fixtures shared by both test targets, beside the reference conversion and
//  the audio files of AudioReferenceFixtures.h and the FLAC headers of
//  FLACFixtures.h, which it imports. VibeImageOfColor is the one solid-color
//  image.
//

#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "AudioReferenceFixtures.h"
#import "FLACFixtures.h"

// A side x side image of one opaque sRGB color, PNG or JPEG.
static inline NSData *VibeImageOfColor(size_t side, CGFloat red, CGFloat green, CGFloat blue, BOOL jpeg) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, space,
                                                 (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetRGBFillColor(context, red, green, blue, 1);
    CGContextFillRect(context, CGRectMake(0, 0, side, side));
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)data,
            (__bridge CFStringRef)(jpeg ? UTTypeJPEG : UTTypePNG).identifier, 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return data;
}
