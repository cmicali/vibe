//
//  VibeFakeHTTP.h
//  Vibe
//
//  A stand-in web server for Open URL: a directory on disk answers as
//  https://fake.vibe.test/<path> and http://fake.local/<path>, over the
//  client's own HTTP boundary (an NSURLProtocol on its sessions). It answers
//  iCloud Drive's lookup too: https://www.icloud.com/iclouddrive/<name> is
//  the root's entry named <name> without its extension, served at a signed
//  address that expires. The link's
//  probe, its stream, its tail and tag reads, and every resend run unchanged
//  against it, with no network. Faults script what real servers do.
//
//  Its serving engine is the tests' too. HTTPStub subclasses the protocol
//  and scripts each answer. The Range rule, the body's pieces, its stall,
//  its lost connection, and its pacing are here alone.
//

#if DEBUG

#import <Foundation/Foundation.h>

@class HTTPTransferClient;

NS_ASSUME_NONNULL_BEGIN

// A server with ranges: the status a Range header gets from a file of `size`
// bytes. 206 for a range inside it, 416 for one starting at or past its end,
// and 200 for none, or for one it cannot read. Sets the body's first byte and
// length, and puts Content-Length in `headers`, and Content-Range for a 206
// or a 416.
NSInteger VibeFakeHTTPRangeStatus(NSString *_Nullable range, uint64_t size,
                                  NSMutableDictionary<NSString *, NSString *> *headers,
                                  uint64_t *first, uint64_t *length);

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

// The fake's protocol. Its answers are the directory's. A subclass serves
// others by overriding answerForRequest:. nil fails as an unknown host.
@interface VibeFakeHTTPProtocol : NSURLProtocol
- (nullable VibeFakeHTTPAnswer *)answerForRequest:(NSURLRequest *)request;
@end

@interface VibeFakeHTTP : NSObject

// `directory` is the server's root. The client's sessions are rebuilt over
// the fake. It then answers every request they send. A host it does not
// serve fails as an unknown host, and is logged. A test sees from the log
// what reached the network. Installing again over an installed fake swaps
// the directory and clears the faults and the log. The sessions stay.
//
// Each file answers as a server with ranges does: a 206 with Content-Range,
// a 416 past its end, a 200 to a request with no Range. Content-Length,
// a strong ETag, and Last-Modified come from its size and mtime, and its
// Content-Type from its extension. A body from an open range (none, or
// `bytes=N-`) is paced in 64 KB pieces. The whole file takes about
// transferSeconds (0: at once), or goes at a `rate` fault's bytes per
// second. A closed range (the probe, a tag read, the tail window) answers at
// once.
+ (void)installWithDirectory:(NSURL *)directory
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(HTTPTransferClient *)client;

// The sessions the fake answers on: what the install hands the client, and
// what a test's own session uses to read the raw answers.
+ (NSURLSessionConfiguration *)sessionConfiguration;

// Puts the client back on the network.
+ (void)uninstallFromClient:(HTTPTransferClient *)client;

+ (BOOL)isInstalled;

// One fault, for the file of that basename or, with nil, every file. NO for
// an unknown kind, or a rate or status missing. Each has a default
// lifetime. `once` NO keeps a fault until clearFaults. `once` YES drops it
// after the first request it changes. stall and rate always last.
//   stall        a paced body delivers up to `after` bytes, then holds until
//                clearFaults (persistent)
//   drop         a paced body ends with a lost connection at file offset
//                `after` (once)
//   etag-change  as drop, and the file takes a new version: its ETag and
//                its Last-Modified move, as a re-upload's would. The resend
//                answers another version (once). An ETag alone moving is the
//                CDN case. The client continues through that one
//   rate         paced bodies arrive at `rate` bytes per second (persistent)
//   latency      every answer's headers come `seconds` late: a server's time
//                to first byte (persistent)
//   no-range     a Range is ignored: a paced 200 of the whole file
//                (persistent)
//   no-length    a paced 200 of the whole file with no Content-Length and no
//                Content-Range (persistent)
//   icy          as no-length, with a radio stream's icy- headers
//                (persistent)
//   status       every answer is `status`, with a short text body
//                (persistent)
//   html         every answer is a 200 web page (persistent)
//   gzip         a 200 with Content-Encoding: gzip. The body is the file's
//                bytes. The client must refuse on the header alone, as no
//                size can be trusted (persistent)
//   expiry       an iCloud lookup's address lives `seconds`, not 15 minutes.
//                0 hands out one already expired, which answers 410
//                (persistent)
+ (BOOL)addFaultOfKind:(NSString *)kind
                  file:(nullable NSString *)file
                 after:(uint64_t)after
               seconds:(NSTimeInterval)seconds
                  rate:(uint64_t)rate
                status:(NSInteger)status
                  once:(nullable NSNumber *)once;
// Lifts every fault. A held body goes on from where it stopped. A file's
// version stays where etag-change moved it.
+ (void)clearFaults;

// {fake, directory, transferSeconds, requests (the count since install),
// faults, transfers (the paced bodies delivering now), log (the last
// requests: seq, t, host, path, range, status, etag, size, delivered,
// firstByte, finished, faults, outcome)}. t, firstByte, and finished are
// seconds since install, stamped where the fake runs.
+ (NSDictionary *)statistics;

@end

NS_ASSUME_NONNULL_END

#endif
