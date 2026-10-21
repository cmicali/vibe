#import "FakeTrackMetadata.h"

@implementation FakeTrackMetadata

- (instancetype)init {
    self = [super init];
    if (self) {
        _key = -1;
    }
    return self;
}

- (void)loadArtIfNeededStillWanted:(BOOL (^)(void))stillWanted completion:(void (^)(VibeImage *))completion {
    self.artStillWanted = stillWanted;
    self.artCompletion = completion;
}

- (void)discardDecodedArt {
    self.discardedArtCount++;
    self.cachedArt = nil;
}

@end
