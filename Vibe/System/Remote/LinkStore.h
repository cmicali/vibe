//
//  LinkStore.h
//  Vibe
//
//  Open URL: an http or https link to an audio file, kept as a local file
//  that plays like any other. Each link is a directory under the root, named
//  by its URL, holding one placeholder and the link's record. Opening the
//  same link again reuses both. The placeholder streams when it plays, as a
//  RemotePlaceholderStore's does, and the download stays for the next play
//  until the budget sends it back to a placeholder.
//

#import <Foundation/Foundation.h>

#import "HTTPTransferClient.h"
#import "LinkRules.h"
#import "RemotePlaceholderStore.h"

NS_ASSUME_NONNULL_BEGIN

// A link that did not open. The code is a VibeLinkError. A Server error
// carries the status under VibeHTTPErrorStatusCodeKey. The error that caused
// it, if any, is under NSUnderlyingErrorKey. Each shell shows its
// link.error string.
extern NSErrorDomain const VibeLinkErrorDomain;

@interface LinkStore : RemotePlaceholderStore

- (instancetype)initWithClient:(HTTPTransferClient *)client
                       rootURL:(NSURL *)rootURL
                indexAttribute:(NSString *)indexAttribute
                downloadBudget:(long long)downloadBudget NS_UNAVAILABLE;

// The app's one store, under <Application Support>/Links. A singleton
// because the remote fetch, installed at launch, must reach the instance
// every open does.
@property (class, nonatomic, readonly) LinkStore *shared;

// rootURL holds one directory per link. The tests pass a temp directory and a
// client over their stub. The store sets the client's allowsURL.
- (instancetype)initWithClient:(HTTPTransferClient *)client
                       rootURL:(NSURL *)rootURL NS_DESIGNATED_INITIALIZER;

// The typed link as a file to open: its placeholder, or its download when
// that is still current. Any thread. The probe and the disk work run off
// main. Completion on main, exactly once, with exactly one of file and
// error. A refused address fails before any request. A probe past its
// deadline (VibeLinkProbeTimeout) fails as unreachable or as the local
// network's.
// The returned block cancels, on main only. A resolve not yet completed
// then completes before the block returns, with VibeLinkErrorCancelled, and
// nothing lands after it. Past the completion it does nothing.
- (dispatch_block_t)resolveURLString:(NSString *)string
                          completion:(void (^)(NSURL *_Nullable file, NSError *_Nullable error))completion;

// Multiplies the probe's deadline. 1 unless a test shortens it.
@property (nonatomic) double probeTimeoutScale;

// The record of the link whose file url is: {url, host, …}, as the Links
// section of System/Remote/AGENTS.md lists it. Nil for a file outside the
// root, or a directory with no record. Any thread. Reads one cached xattr.
- (nullable NSDictionary *)recordOfLinkFileURL:(NSURL *)url;

// What the shell shows for a failed open: the error's link.error string. A
// Server error names its status. Any error outside the link domain reads as
// unreachable. A disk failure is one. Nil for a cancel, which shows nothing.
+ (nullable NSString *)messageForError:(nullable NSError *)error;

// Deletes each link not opened for 30 days that no URL in kept lies in. Once
// per launch, after the restore, so kept holds what the shell restored. A
// saved playlist naming a deleted link finds its entry missing. Off main, on
// the store's queue.
- (void)pruneKeepingURLs:(NSSet<NSURL *> *)kept;

@end

NS_ASSUME_NONNULL_END
