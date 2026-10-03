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
// files Dropbox files, ids are paths. Indexed once here, so a request is a
// lookup. The client's sessions are rebuilt over the fake and the account is
// linked as a completed sign-in would be. A whole download takes about
// transferSeconds, delivered in pieces so a loading bar has something to
// show; ranged reads answer at once.
+ (void)installWithDirectory:(NSURL *)directory
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(DropboxClient *)client;

// Signs the fake account out and puts the client back on the network.
+ (void)uninstallFromClient:(DropboxClient *)client;

+ (BOOL)isInstalled;

// Requests answered so far, by endpoint.
+ (NSDictionary<NSString *, NSNumber *> *)statistics;

@end

NS_ASSUME_NONNULL_END

#endif
