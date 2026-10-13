//
//  CloudFileMaterializerInternal.h
//  Vibe
//
//  The state and calls the debug seam's fake transfer shares with the real
//  ones (CloudFileMaterializer+Debug.m).
//

#import "CloudFileMaterializer.h"

#include <os/lock.h>

NS_ASSUME_NONNULL_BEGIN

@interface CloudFileMaterializationToken ()
@property (nonatomic, getter=isCancelled) BOOL cancelled;
- (instancetype)initForMaterializer;
@end

@interface CloudFileMaterializer () {
    // Set before dispatch, so a cancel before entry lands.
    CloudFileMaterializationToken *_token;
    // What -cancel, callable from any thread, runs: the coordinator's cancel,
    // the remote backend's, or the fake transfer's signal.
    dispatch_block_t  _cancelTransfer;
    os_unfair_lock    _lock;
}

- (BOOL)installCancelTransfer:(dispatch_block_t)cancel token:(CloudFileMaterializationToken *)token;
- (void)finishTransferForToken:(CloudFileMaterializationToken *)token;

@end

NSError *VibeMaterializationCancelledError(void);

NS_ASSUME_NONNULL_END
