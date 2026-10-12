//
//  AudioFileHandle+Debug.m
//  Vibe
//

#import "AudioFileHandle+Debug.h"

#if DEBUG

@implementation AudioFileHandle (Debug)

+ (void)debugSetMountRule:(NSNumber *(^)(NSURL *))rule {
    VibeNetworkReadAheadDebugSetMountRule(rule);
}

+ (void)debugSetBeforeRead:(int (^)(NSURL *, uint64_t, uint64_t))beforeRead {
    VibeNetworkReadAheadDebugSetBeforeRead(beforeRead);
}

+ (void)debugSetRetryScale:(double)scale {
    VibeNetworkReadAheadDebugSetRetryScale(scale);
}

+ (NSInteger)debugLiveReadAheads {
    return VibeNetworkReadAheadDebugLive();
}

+ (NSInteger)debugOrphanedReadAheads {
    return VibeNetworkReadAheadDebugOrphaned();
}

@end

#endif
