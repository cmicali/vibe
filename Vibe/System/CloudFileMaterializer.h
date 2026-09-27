//
//  CloudFileMaterializer.h
//  Vibe
//
//  Downloads a file provider's placeholder as an abortable step. Opening a
//  dataless file blocks in the kernel until the provider finishes, and
//  NSFileCoordinator's -cancel is the one documented way out, so the download
//  is coordinated here rather than left inside whatever opens the file.
//
//  TRAP: cancelling stops us waiting. Whether the provider abandons the
//  transfer is its business (a replicated extension's NSProgress may be
//  cancelled, nothing promises it), so it frees the lane and the thread at
//  once, not the bandwidth.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Created before the caller dispatches its worker, so -cancel reaches a call
// that has not yet entered materializeURL:token:error:. A token, not a claim:
// each caller owns its materializer, and a later preparation supersedes it.
@interface CloudFileMaterializationToken : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface CloudFileMaterializer : NSObject

// The caller's role in the debug transfer trace; set once at creation.
@property (nonatomic, copy, nullable) NSString *label;

// Registers one call before dispatch, cancelling any earlier one.
- (CloudFileMaterializationToken *)prepareMaterialization;

// Blocks until url's data is on disk; a local file costs only the probe.
// Background only: it blocks for a download, and coordinating on main is how
// an app deadlocks against its own presenters.
- (BOOL)materializeURL:(NSURL *)url
                 token:(CloudFileMaterializationToken *)token
                 error:(NSError *__autoreleasing _Nullable *_Nullable)error;

// Any thread, returns at once; the call returns NO with NSUserCancelledError.
// Per-token, not a latch: the next preparation is independent work.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
