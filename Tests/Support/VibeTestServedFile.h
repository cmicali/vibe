//
//  VibeTestServedFile.h
//
//  A served handle with no decoder, for the coordinator's stage-2 tests. A
//  missing or empty file fails with an error, as a real handle's open does.
//

#import <Foundation/Foundation.h>

#import "AudioFileMaterializationCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface VibeTestServedFile : NSObject <ServedFileHandle>
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError *__autoreleasing _Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
@end

// The opener the tests pass when the open itself is not under test.
static VibeAudioFileOpener const VibeTestServedFileOpener =
        ^id<ServedFileHandle>(NSURL *url, BOOL (^interrupted)(void), NSError **error) {
    return [[VibeTestServedFile alloc] initWithURL:url error:error];
};

NS_ASSUME_NONNULL_END
