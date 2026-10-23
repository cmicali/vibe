//
//  VibeFakeHTTPProtocol.h
//  Vibe
//
//  The fake web server's serving engine, which the tests' HTTPStub shares.
//  HTTPStub subclasses the protocol and scripts each answer. The Range rule,
//  the body's pieces, its stall, its lost connection, and its pacing are
//  here alone. VibeFakeHTTP.h is the directory that answers.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// An answer's piece unless it sets its own.
static const uint64_t kVibeFakeHTTPPieceBytes = 64 * 1024;

// A server with ranges: the status a Range header gets from a file of `size`
// bytes. 206 for a range inside it, 416 for one starting at or past its end,
// and 200 for none, or for one it cannot read. Sets the body's first byte and
// length, and puts Content-Length in `headers`, and Content-Range for a 206
// or a 416.
NSInteger VibeFakeHTTPRangeStatus(NSString *_Nullable range, uint64_t size,
                                  NSMutableDictionary<NSString *, NSString *> *headers,
                                  uint64_t *first, uint64_t *length);

// A request's body. A protocol sees a POST's body as a stream.
NSData *_Nullable VibeFakeHTTPBodyOfRequest(NSURLRequest *request);

// One answer, made when its request arrives. A failure, a redirect, or a
// response and its body. The body goes out in pieces after the latency, on
// the fake's own queue, and the client is told on the loader's thread.
@interface VibeFakeHTTPAnswer : NSObject
@property (nonatomic, nullable) NSError *error;
// With `response` as the 3xx. The session follows it or refuses it.
@property (nonatomic, nullable) NSURLRequest *redirect;
@property (nonatomic, nullable) NSHTTPURLResponse *response;
// The body's length, and its bytes by offset into it.
@property (nonatomic) uint64_t length;
@property (nonatomic, copy, nullable) NSData *_Nullable (^bytes)(uint64_t offset, uint64_t length);
// 64 KB unless set.
@property (nonatomic) uint64_t piece;
// Before the response, and before each piece.
@property (nonatomic) NSTimeInterval latency;
@property (nonatomic) NSTimeInterval interval;
// Body offsets, UINT64_MAX for none. The body holds once it reaches holdAt,
// and is asked again shortly. It ends with a lost connection at cutAt.
@property (nonatomic) uint64_t holdAt;
@property (nonatomic) uint64_t cutAt;
// The lost connection waits until this answers YES too.
@property (nonatomic, copy, nullable) BOOL (^ready)(void);
// Asked before each piece, and each time a hold is asked again, with the
// body bytes sent. It may move holdAt, cutAt, and interval.
@property (nonatomic, copy, nullable) void (^beforePiece)(VibeFakeHTTPAnswer *answer, uint64_t delivered);
// Told "running" at the response and each piece, "stalled" while held, then
// "complete", "dropped", or "cancelled", with the body bytes sent. Cancelled
// is a stop before the end.
@property (nonatomic, copy, nullable) void (^progress)(NSString *outcome, uint64_t delivered);
@end

// The fake's protocol. It delivers each answer.
@interface VibeFakeHTTPProtocol : NSURLProtocol
@end

// Its answers are the directory's (VibeFakeHTTP.m). A subclass serves others
// by overriding answerForRequest:. nil fails as an unknown host.
@interface VibeFakeHTTPProtocol (Directory)
- (nullable VibeFakeHTTPAnswer *)answerForRequest:(NSURLRequest *)request;
@end

NS_ASSUME_NONNULL_END
