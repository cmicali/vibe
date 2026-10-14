//
//  VibeFakeGoogleDrive.h
//  Vibe (iOS)
//
//  A stand-in Google Drive for the simulator: a directory on disk answers as
//  the account's My Drive, over the client's own HTTP boundary (an
//  NSURLProtocol on its sessions), so the mirror, the browser, search and
//  every open run unchanged against a scripted tree with no sign-in, no
//  network and no account. The sign-in is Google's web sheet, which only a
//  human can fill.
//
//  Its serving engine is VibeFakeHTTPProtocol.h: the Range rule, the paced
//  pieces, the stall and the lost connection are there. This file holds the
//  tree as Drive answers it, its faults, and its log.
//

#if DEBUG

#import <Foundation/Foundation.h>

@class OAuthAccountClient;

NS_ASSUME_NONNULL_BEGIN

@interface VibeFakeGoogleDrive : NSObject

// `directory` is My Drive: its folders are Drive folders and its files Drive
// files. Each item's id is made from its path, and My Drive's own is
// "fakeroot", which the alias "root" also names. Each file's md5Checksum
// stands for its version and moves when its size or mtime does, as a
// re-upload's would. Indexed once here, so a request is a lookup. The
// client's sessions are rebuilt over the fake and the account is linked as
// a completed sign-in would be. Installing again over an installed fake
// swaps the tree and clears the faults and the log, leaving the sessions
// alone. A media download is paced in 64 KB pieces so the whole file takes
// about transferSeconds (0: at once), or at a `rate` fault's bytes per
// second. A resend from a Range is paced the same way from its offset, and
// a closed range (a tag read or the tail window) answers at once.
+ (void)installWithDirectory:(NSURL *)directory
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(OAuthAccountClient *)client;

// Signs the fake account out and puts the client back on the network.
+ (void)uninstallFromClient:(OAuthAccountClient *)client;

+ (BOOL)isInstalled;

// One fault, for the file of that basename or, with nil, every file. NO for
// an unknown kind.
//   stall          a download delivers up to `after` bytes, then holds
//                  until clearFaults (persistent)
//   drop           once: the body ends with a lost connection at `after`
//   version-change once: as drop, and the file takes a new md5Checksum, so
//                  the resend's lookup names another version
//   throttle       once: a download answers 403 rateLimitExceeded
//   expired-token  once: a download answers 401
//   rate           downloads are paced at `rate` bytes per second
//                  (persistent)
//   latency        every media answer comes `seconds` late (persistent)
+ (BOOL)addFaultOfKind:(NSString *)kind
                  file:(nullable NSString *)file
                 after:(uint64_t)after
               seconds:(NSTimeInterval)seconds
                  rate:(uint64_t)rate;
+ (void)clearFaults;

// {requests: {endpoint: count}, faults, log (the last requests: endpoint,
// file, range, status, delivered, outcome)}.
+ (NSDictionary *)statistics;

@end

NS_ASSUME_NONNULL_END

#endif
