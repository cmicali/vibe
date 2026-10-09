//
//  HTTPTransferClient.h
//  Vibe
//
//  A remote file over HTTP: a download streamed into a file as its bytes
//  arrive, a ranged read, and a probe of the first bytes. A resend continues
//  a download rather than starting it over, and only for the same version.
//  The defaults are plain HTTP: a GET of an NSURL target, with the version
//  from the ETag or Last-Modified. A subclass changes them through the hooks
//  in HTTPTransferClientInternal.h (DropboxClient).
//
//  Thread-safe. Completions run on an arbitrary queue unless stated.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const VibeHTTPErrorDomain;
// The status of a VibeHTTPErrorStatus, an NSNumber.
extern NSErrorUserInfoKey const VibeHTTPErrorStatusCodeKey;

typedef NS_ERROR_ENUM(VibeHTTPErrorDomain, VibeHTTPError) {
    VibeHTTPErrorCancelled = 1,
    // The server answered a failure status, after any retries.
    VibeHTTPErrorStatus,
    // A download's resend answered another version than its first response:
    // the bytes written cannot be trusted, and are deleted.
    VibeHTTPErrorVersionChanged,
    // A download ended at another length than its first response's size.
    VibeHTTPErrorLengthMismatch,
    // allowsURL refused the request's URL, or a redirect's.
    VibeHTTPErrorRefusedURL,
};

@interface HTTPTransferClient : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;

// Asked of every request's URL before it is sent, and of every redirect's.
// A refusal fails the transfer with VibeHTTPErrorRefusedURL. Nil allows all.
@property (atomic, copy, nullable) BOOL (^allowsURL)(NSURL *url);

// The target streamed into destination as the bytes arrive, so its size on
// disk is the transfer's progress. Made once, at the first accepted
// response: a resend (a throttle, a dropped connection) continues it with a
// Range header rather than starting over, and only for the same version. A
// destination a cancelled or dropped download kept is continued the same
// way. The completion carries the first response's metadata; on failure
// destination is gone, unless the link ended the transfer. A file whose
// length differs from that metadata's size fails, and one dropped after its
// last byte is complete.
// progress, on the download's serial delivery queue and never after the
// completion, is called with the bytes on disk once the file is made, then
// after each write. size and version are the metadata's, -1 and nil when it
// names none.
// The returned block cancels, any thread, at any point: before the request
// starts it never starts.
- (dispatch_block_t)downloadTarget:(id)target
                             toURL:(NSURL *)destination
                          progress:(nullable void (^)(uint64_t bytesWritten, int64_t size,
                                                      NSString *_Nullable version))progress
                        completion:(void (^)(NSDictionary *_Nullable metadata, NSError *_Nullable error))completion;

// `length` bytes of the target from `offset`, through a Range header: how a
// tag parse reads a file it does not download. Fewer bytes come back only at
// the file's end. metadata is the response's. The returned block cancels, as
// the download's does.
- (dispatch_block_t)readTarget:(id)target
                        offset:(uint64_t)offset
                        length:(uint64_t)length
                    completion:(void (^)(NSData *_Nullable data, NSDictionary *_Nullable metadata,
                                         NSError *_Nullable error))completion;

// Up to `length` bytes from the target's start, and the response that
// carried them: what a caller reads to learn a file before downloading it.
// A GET with a Range, on the download's session, cancelled once the bytes
// are in or the body ends. A server ignoring the range answers 200 and the
// whole file's start. The returned block cancels, as the download's does.
- (dispatch_block_t)probeTarget:(id)target
                         length:(uint64_t)length
                     completion:(void (^)(NSDictionary *_Nullable metadata, NSHTTPURLResponse *_Nullable response,
                                          NSData *_Nullable bytes, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
