//
//  VibeFakeDropbox.h
//  Vibe (iOS)
//
//  A stand-in Dropbox for the simulator: a directory on disk answers as the
//  account, over the client's own HTTP boundary (an NSURLProtocol on its
//  sessions), so the mirror, the browser, search and every open run unchanged
//  against a scripted tree with no sign-in, no network and no account. The
//  sign-in is Dropbox's web sheet, which only a human can fill, and the mirror
//  is lazy — a folder exists locally only once something listed it — which is
//  exactly the class of bug a scripted tree reproduces.
//

#if DEBUG

#import <Foundation/Foundation.h>

@class DropboxClient;

NS_ASSUME_NONNULL_BEGIN

@interface VibeFakeDropbox : NSObject

// `directory` is the account's root: its folders are Dropbox folders, its
// files Dropbox files, ids are paths, and each file has a rev, named in every
// answer's Dropbox-API-Result and readable as a `rev:` path, that moves when the file's size or mtime does, as a
// re-upload's would. Indexed once here, so a request is a lookup. The client's
// sessions are rebuilt over the fake and the account is linked as a completed
// sign-in would be; installing again over an installed fake swaps the tree
// and clears the faults and the log, leaving the sessions alone. A download
// is paced in 64 KB pieces so the whole file takes about transferSeconds (0:
// at once), or at a `rate` fault's bytes per second; a resend from a Range
// is paced the same way from its offset, and a closed range — a tag read or
// the tail window — answers at once. Every answer carries Dropbox-API-Result.
+ (void)installWithDirectory:(NSURL *)directory
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(DropboxClient *)client;

// Signs the fake account out and puts the client back on the network.
+ (void)uninstallFromClient:(DropboxClient *)client;

+ (BOOL)isInstalled;

// One fault, for the file of that basename or, with nil, every file; each
// drives one of the client's streaming roads. NO for an unknown kind.
//   stall       a download delivers up to `after` bytes, then nothing until
//               resumeStalls (persistent)
//   drop        once: the body ends with a lost connection at `after` bytes
//   rev-change  once: as drop, and the file takes a new rev, so the resend's
//               Dropbox-API-Result names another version
//   throttle    once: a download answers 429 with Retry-After `seconds`
//   expired-token once: a download answers 401 expired_access_token
//   tail-fail   the tail read (the closed range of the file's last
//               VibeDropboxTailWindowBytes) answers 500 (persistent)
//   slow-tail   the tail read answers after `seconds` (persistent)
//   slow-tags   any other ranged read — the tag parse's — answers after
//               `seconds` (persistent)
//   rate        downloads are paced at `rate` bytes per second (persistent)
//   latency     every files/download answers `seconds` late: a server's time
//               to first byte, which the tail read pays beside the download's
//               (persistent)
+ (BOOL)addFaultOfKind:(NSString *)kind
                  file:(nullable NSString *)file
                 after:(uint64_t)after
               seconds:(NSTimeInterval)seconds
                  rate:(uint64_t)rate;
+ (void)clearFaults;
// Lifts every stall; the stalled downloads go on from where they stopped.
+ (void)resumeStalls;

// {requests: {endpoint: count}, downloads: {whole, resume, ranged, tail},
// faults, transfers (the downloads delivering now: delivered, size, stalled),
// log (the last downloads and reads: kind, range, status, rev, delivered,
// outcome)}.
+ (NSDictionary *)statistics;

@end

NS_ASSUME_NONNULL_END

#endif
