//
//  CloudFileMaterializer.h
//  Vibe
//
//  Pulls a file provider's placeholder down to disk as an explicit, ABORTABLE
//  step, so that background work which needs a cloud file's bytes can be told
//  to stop.
//
//  The reason it exists is that an ordinary read cannot be interrupted. Opening
//  a dataless file — TagLib's read, AVAudioFile's open — blocks in the kernel
//  until the provider finishes, however long that takes and whatever the app
//  has decided to do meanwhile: a background metadata parse that has started
//  downloading a 60MB track owns its lane for the whole transfer, and the only
//  lever left is refusing to start new ones. NSFileCoordinator's -cancel is the
//  one documented way out ("any current invocation will stop waiting and return
//  immediately", from any thread), which is why the download is coordinated
//  here rather than left implicit inside whatever opens the file next.
//
//  TRAP: cancelling stops US waiting. Whether the provider abandons the
//  transfer is its own business — a replicated extension's fetchContents gets
//  an NSProgress the system MAY cancel once nothing waits on it, but nothing
//  promises that. So this frees the lane and the thread at once; it does not
//  promise to free the bandwidth.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One prepared materialization call. The materializer creates it before the
// caller dispatches the worker, so -cancel can invalidate work which is
// committed but has not entered materializeURL:token:error: yet.
//
// A token and not a claim: nothing contends for a materializer — each caller
// owns one for its own serial lane — so there is no ownership to take and no
// waiter to serve. What crosses the dispatch boundary is an opaque handle
// proving the call is still the current one, and a later preparation
// supersedes the older handle rather than queueing behind it. Same shape as
// Mac/App's OpenRequestToken.
@interface CloudFileMaterializationToken : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface CloudFileMaterializer : NSObject

// Registers one call before it is dispatched. A later preparation supersedes
// the earlier token, just as -cancel does; callers use one materializer for one
// serial lane, so there is only one prepared or running call at a time.
- (CloudFileMaterializationToken *)prepareMaterialization;

// Blocks until url's data is on disk, and answers whether it got there. A
// local file is already materialized, so this only performs the cheap
// placeholder probe rather than coordinating a read. token must have been
// returned by this materializer before the worker was dispatched.
//
// BACKGROUND QUEUES ONLY: it blocks for the length of a download, and file
// coordination on the main thread is how an app deadlocks against its own
// presenters.
- (BOOL)materializeURL:(NSURL *)url
                 token:(CloudFileMaterializationToken *)token
                 error:(NSError *__autoreleasing _Nullable *_Nullable)error;

// Aborts the prepared or in-progress call, if there is one. Any thread,
// returns immediately, and materializeURL:token:error: returns NO with
// NSUserCancelledError. Cancelling is per-token, not a latch: the next
// prepareMaterialization creates independent work, so the caller's own gate —
// the cloud lane's suspension — is what decides when work resumes.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
