//
//  HTTPTransferClientInternal.h
//  Vibe
//
//  The hooks a subclass overrides, and the seams the tests and the debug
//  channel use. Every hook gets the transfer's own `state`, made empty with
//  it and kept across its attempts. The base never reads it.
//

#import "HTTPTransferClient.h"

NS_ASSUME_NONNULL_BEGIN

@interface HTTPTransferClient ()

// Calls and ranged reads, answered whole. Its own queue, so a tag read never
// waits behind a download's disk writes.
@property (nonatomic, readonly) NSURLSession *callSession;
// Downloads and probes, streamed through the client as their delegate.
@property (nonatomic, readonly) NSURLSession *downloadSession;

// Rebuilds both sessions over `configuration`, nil for the one the client
// was made with, finishing what is in flight on the old ones: how the debug
// channel puts a fake server under the client and takes it away again.
- (void)useSessionConfiguration:(nullable NSURLSessionConfiguration *)configuration;

// Multiplies every retry's wait, a resume's and a throttle's. 1 unless a test
// scripting drops and 429s shortens them, which would each wait real seconds.
@property (nonatomic) double retryDelayScale;

#pragma mark Hooks

// The request for one attempt, any thread, exactly one of request and error.
// The base adds the Range header. The default is a GET of the target, an
// NSURL, with identity encoding.
- (void)makeRequestForTarget:(id)target
                       state:(NSMutableDictionary<NSString *, id> *)state
                  completion:(void (^)(NSMutableURLRequest *_Nullable request, NSError *_Nullable error))completion;

// An attempt the server answered with a failure status. Exactly one of
// resend and fail runs. The default waits and resends a 429 or a 503
// (VibeHTTPRetryDelay), and fails anything else with VibeHTTPErrorStatus.
- (void)handleFailureStatus:(NSInteger)status
                       data:(nullable NSData *)data
                 retryAfter:(nullable NSString *)retryAfter
                      state:(NSMutableDictionary<NSString *, id> *)state
                    attempt:(NSInteger)attempt
                     resend:(void (^)(NSInteger attempt))resend
                       fail:(void (^)(NSError *error))fail;
// Not a hook. The default's wait and resend: YES when it scheduled one.
- (BOOL)resendAfterStatus:(NSInteger)status
               retryAfter:(nullable NSString *)retryAfter
                  attempt:(NSInteger)attempt
                   resend:(void (^)(NSInteger attempt))resend;

// An accepted response's metadata, as the completions carry it. The default
// is etag, lastModified, contentType, contentDisposition, and url, and size
// (VibeHTTPSizeFromHeaders) when the headers state it.
- (nullable NSDictionary *)metadataOfResponse:(NSHTTPURLResponse *)response
                                       state:(NSMutableDictionary<NSString *, id> *)state;
// What names the metadata's bytes, nil for nothing: no resend continues a
// download it began. The default is VibeHTTPVersionFromHeaders.
- (nullable NSString *)versionOfMetadata:(nullable NSDictionary *)metadata;
// The file's size in the metadata, -1 when it names none.
- (int64_t)sizeOfMetadata:(nullable NSDictionary *)metadata;
// Not a hook. The CDN case (VibeHTTPIsSameFileUnderAnotherETag), on the
// size and lastModified of both.
- (BOOL)isSameFileUnderAnotherETag:(NSDictionary *)metadata asMetadata:(NSDictionary *)pinned;
// The error a transfer fails with for the base's own reasons.
- (NSError *)errorWithCode:(VibeHTTPError)code description:(NSString *)description;
// Not a hook. Whether a download that ended with `error` keeps its file for
// the next download to continue: a cancel (errorWithCode:'s) or a lost
// connection, which the link ended. A transfer its own answer ended would
// only fail again from the same bytes.
- (BOOL)keepsPartAfterError:(nullable NSError *)error;
// The log lines' prefix.
- (NSString *)logName;
// How the log lines name a target. Never a whole link, whose query or user
// info can hold a key. The default is an NSURL's host and last path
// component.
- (NSString *)descriptionOfTarget:(id)target;

@end

NS_ASSUME_NONNULL_END
