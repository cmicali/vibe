//
//  DropboxSearch.h
//  Vibe (iOS)
//
//  The search screen's Dropbox section: files/search_v2's answer to one
//  query, the rows drawn from it, and which of its files the mirror holds
//  bytes for. Only a new query asks Dropbox. It waits for a pause in typing.
//
//  Main thread only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class DropboxMirror;

@interface DropboxSearch : NSObject

// Asks DropboxMirror.shared.
- (instancetype)init;
- (instancetype)initWithMirror:(DropboxMirror *)mirror NS_DESIGNATED_INITIALIZER;

// The answer's entries minus what the playlist already lists.
@property (nonatomic, readonly) NSArray<NSDictionary *> *hits;
@property (nonatomic, readonly, getter=isSearching) BOOL searching;
// The answer to the query was an error, not an empty list.
@property (nonatomic, readonly) BOOL failed;
// Of the answer's files, those the mirror holds bytes for, by path_lower.
@property (nonatomic, readonly) NSSet<NSString *> *downloaded;
// The playlist's tracks as lowercase Dropbox paths, for the exclusion.
@property (nonatomic, copy) NSSet<NSString *> *playlistPaths;
// On main, when an answer or its count of downloads lands.
@property (nonatomic, copy, nullable) void (^changeHandler)(void);

// A new query asks after the pause. The query in hand re-applies the
// exclusion to its answer and asks nothing.
- (void)searchQuery:(NSString *)query;
// No pending or in-flight answer and none in hand; the next query asks.
- (void)reset;
// A download landed in the mirror, so the count may have moved.
- (void)downloadsDidChange;

@end

NS_ASSUME_NONNULL_END
