//
//  AudioTrackMetadataLoaderInternal.h
//  Vibe
//


#import "AudioTrackMetadataLoader.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataLoader (Internal)

// The cache calls this only after removing a priority loader from service, so
// no new work can arrive. Existing operations keep their construction-time
// configuration and the completion fires after all of them finish.
- (void)retireWithCompletion:(dispatch_block_t)completion;

@end

NS_ASSUME_NONNULL_END
