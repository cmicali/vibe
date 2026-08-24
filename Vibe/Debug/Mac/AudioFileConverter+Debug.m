//
//  AudioFileConverter+Debug.m
//  Vibe
//

#import "AudioFileConverter+Debug.h"

#if DEBUG

#import "AudioFileConverterInternal.h"

@implementation AudioFileConverter (Debug)

- (id)debugArmOmitNextSourceTrashURL {
    NSAssert(NSThread.isMainThread, @"FLAC disposal faults must be armed on the main thread");
    if (self.nextSourceTrashResultingURLFilter) {
        return nil;
    }
    NSUUID *faultIdentity = NSUUID.UUID;
    self.nextSourceTrashResultingURLFilter =
            ^NSURL *(BOOL moved, NSURL *resultingURL) {
        (void)faultIdentity;
        return moved ? nil : resultingURL;
    };
    return self.nextSourceTrashResultingURLFilter;
}

- (void)debugClearPendingSourceTrashURLFault {
    NSAssert(NSThread.isMainThread, @"FLAC disposal faults must be cleared on the main thread");
    self.nextSourceTrashResultingURLFilter = nil;
}

- (void)debugCancelPendingSourceTrashURLFaultWithOwner:(id)owner {
    NSAssert(NSThread.isMainThread, @"FLAC disposal faults must be cancelled on the main thread");
    id currentOwner = self.nextSourceTrashResultingURLFilter;
    if (currentOwner == owner) {
        self.nextSourceTrashResultingURLFilter = nil;
    }
}

@end

#endif
