//
//  PlatformColor.m
//  Vibe
//

#import "PlatformColor.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

VibeColor *VibeColorFromHexString(NSString *hex) {
    if (hex.length == 0) {
        return nil;
    }
    NSString *digits = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (digits.length != 6) {
        return nil;
    }
    unsigned int value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:digits];
    if (![scanner scanHexInt:&value] || !scanner.isAtEnd) {
        return nil;
    }
    CGFloat r = ((value >> 16) & 0xFF) / 255.0;
    CGFloat g = ((value >> 8) & 0xFF) / 255.0;
    CGFloat b = (value & 0xFF) / 255.0;
    return [VibeColor colorWithRed:r green:g blue:b alpha:1];
}

NSString *VibeHexStringFromColor(VibeColor *color) {
    if (!color) {
        return nil;
    }
    CGFloat r = 0, g = 0, b = 0, a = 0;
#if TARGET_OS_OSX
    NSColor *converted = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!converted) {
        return nil;
    }
    [converted getRed:&r green:&g blue:&b alpha:&a];
#else
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        return nil;
    }
#endif
    unsigned int ri = (unsigned int)lround(MIN(MAX(r, 0), 1) * 255);
    unsigned int gi = (unsigned int)lround(MIN(MAX(g, 0), 1) * 255);
    unsigned int bi = (unsigned int)lround(MIN(MAX(b, 0), 1) * 255);
    return [NSString stringWithFormat:@"#%02X%02X%02X", ri, gi, bi];
}
