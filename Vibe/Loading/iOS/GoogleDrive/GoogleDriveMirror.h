//
//  GoogleDriveMirror.h
//  Vibe (iOS)
//
//  The linked Google Drive account's My Drive as local files. What every
//  account's mirror shares is AccountMirror's, and the placeholders, their
//  fetch, the ranged read and the download budget are
//  RemotePlaceholderStore's. This class lists, names and searches Drive.
//
//  A Drive item is its id, never its name. Each mirror directory's index
//  records its folder's id, and each name in it against the id it stands
//  for, with the version the name holds (GoogleDriveRules.h). A local name
//  is a slot: once given, it stays while it still fits the Drive name, so a
//  duplicate name's copy suffix never moves to another file.
//

#import <Foundation/Foundation.h>

#import "AccountMirror.h"
#import "GoogleDriveClient.h"

NS_ASSUME_NONNULL_BEGIN

@interface GoogleDriveMirror : AccountMirror

- (instancetype)initWithClient:(HTTPTransferClient *)client
                       rootURL:(NSURL *)rootURL
                indexAttribute:(NSString *)indexAttribute
                downloadBudget:(long long)downloadBudget NS_UNAVAILABLE;

// The app's one Google Drive mirror over the one client.
@property (class, nonatomic, readonly) GoogleDriveMirror *shared;

// Whether this build has a Google client id. A build without one lists no
// Google Drive anywhere (AccountMirror.mirrors). A debug build always does,
// for the fake.
@property (class, nonatomic, readonly, getter=isConfigured) BOOL configured;

// rootURL holds one directory per account; the tests pass a temp directory.
// Past downloadBudget bytes of downloads, the oldest go back to placeholders.
- (instancetype)initWithClient:(GoogleDriveClient *)client
                       rootURL:(NSURL *)rootURL
                downloadBudget:(long long)downloadBudget NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) GoogleDriveClient *client;

// The Drive folder id a mirror directory stands for: "root" for the
// account's own, else the id its index records. Nil outside the linked
// account, and for a directory no listing made.
- (nullable NSString *)folderIDForURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
