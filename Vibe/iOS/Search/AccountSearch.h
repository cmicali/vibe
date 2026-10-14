//
//  AccountSearch.h
//  Vibe (iOS)
//
//  One account's section of the search screen: the service's answer to one
//  query, the rows drawn from it, and which of its files the mirror holds
//  bytes for. Only a new query asks the service. It waits for a pause in
//  typing.
//
//  Main thread only.
//

#import <Foundation/Foundation.h>

@class AccountMirror;

NS_ASSUME_NONNULL_BEGIN

@interface AccountSearch : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithMirror:(AccountMirror *)mirror NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) AccountMirror *mirror;
// The answer's entries minus what the playlist already lists.
@property (nonatomic, readonly) NSArray<NSDictionary *> *hits;
@property (nonatomic, readonly, getter=isSearching) BOOL searching;
// The answer to the query was an error, not an empty list.
@property (nonatomic, readonly) BOOL failed;
// Of the answer's files, those the mirror holds bytes for, by the mirror's
// identityOfEntry:.
@property (nonatomic, readonly) NSSet<NSString *> *downloaded;
// The playlist's tracks by the mirror's identityOfURL:, for the exclusion.
@property (nonatomic, copy) NSSet<NSString *> *playlistIdentities;
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
