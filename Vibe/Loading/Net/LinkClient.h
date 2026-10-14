//
//  LinkClient.h
//  Vibe
//

#import <Foundation/Foundation.h>

#import "HTTPTransferClient.h"

NS_ASSUME_NONNULL_BEGIN

// The client every link goes through: the plain client, an iCloud Drive
// share's lookup before each request to it, and a Dropbox folder's listing.
// The lookup's address lives about 15 minutes, so each request gets one
// looked up in the last 10. A refused address is looked up again once. The
// checksum the lookup states is the version, so a resend after a fresh lookup
// continues the same bytes.
@interface LinkClient : HTTPTransferClient

// A Dropbox folder link's files, listed as its share page lists them
// (DropboxLinkRules.h): the page, for its t cookie, then the entries a page at
// a time. Each file is {name, size, url, modified?}, in the listing's order,
// with a folder's files in its place. name is the folder's own, nil when no
// page states one. timeout bounds each request. Any failure fails the whole
// listing, so a dropped connection never reads as files that left. An answer
// that is not a listing fails with VibeLinkErrorNotAudio. Completion on any
// thread, exactly once, with exactly one of files and error. The returned
// block cancels, on any thread. No request starts after it, and the
// completion then fails with VibeHTTPErrorCancelled.
- (dispatch_block_t)listDropboxFolder:(NSDictionary<NSString *, NSString *> *)token
                              timeout:(NSTimeInterval)timeout
                           completion:(void (^)(NSString *_Nullable name, NSArray<NSDictionary *> *_Nullable files,
                                                NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
