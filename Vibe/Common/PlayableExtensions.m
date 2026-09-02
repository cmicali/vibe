//
//  PlayableExtensions.m
//  Vibe
//

#import "PlayableExtensions.h"

@implementation PlayableExtensions

+ (NSArray<NSString *> *)ordered {
    static NSArray<NSString *> *ordered;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ordered = @[@"wav", @"wave", @"bwf", @"aif", @"aiff", @"flac",
                    @"m4a", @"mp4", @"qta", @"aac", @"mp3", @"mp2"];
    });
    return ordered;
}

+ (NSSet<NSString *> *)lookup {
    static NSSet<NSString *> *lookup;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lookup = [NSSet setWithArray:PlayableExtensions.ordered];
    });
    return lookup;
}

@end
