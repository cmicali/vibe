//
//  MetadataParseRunner.h
//  Vibe
//
//  Runs one stage-2 parse attempt through the order its steps must happen in:
//  take the cross-lane claim, take an answer that is already there over doing
//  the work again, parse only when there is none, then serve the duplicate
//  rows that waited on it.
//
//  Foundation-only, with every effect behind the delegate, because the
//  ordering is the part that breaks — the file read, the tag parse and the
//  cache are not. The loader supplies them; MetadataParseCoordinator owns the
//  claim bookkeeping underneath.
//
//  One per loader, not one per attempt: it holds no state of its own, so
//  runForParticipant:key: is re-entrant and every scan worker calls the same
//  instance at once.
//

#import <Foundation/Foundation.h>

@class MetadataParseCoordinator;

NS_ASSUME_NONNULL_BEGIN

@protocol MetadataParseRunnerDelegate <NSObject>

// Whether this participant already holds real metadata. Asked on the way in
// and again under the claim, so it must re-read live state rather than answer
// from anything the runner captured.
- (BOOL)parseRunnerIsResolved:(id)participant;

// One cache read, publishing the participant on a hit. YES means served: the
// parse is then not run at all.
- (BOOL)parseRunnerServeFromCache:(id)participant;

// The blocking parse — a file read and a tag parse — and its cache write.
- (void)parseRunnerReadAndCache:(id)participant;

// Publishes what the parse produced. Deliberately separate from it, because
// the claim is released in between: a duplicate row's next attempt must not
// queue behind a publish.
- (void)parseRunnerPublish:(id)participant;

@end

@interface MetadataParseRunner : NSObject

// The delegate is held weakly, the way the loader that implements it holds
// this object strongly. A runner whose delegate has gone does nothing.
- (instancetype)initWithCoordinator:(MetadataParseCoordinator *)coordinator
                           delegate:(id<MetadataParseRunnerDelegate>)delegate;

// One parse attempt for participant, coordinated on key — the cache identity,
// which several participants can share. A nil key is uncoordinated: it always
// owns itself and never has waiters.
- (void)runForParticipant:(id)participant key:(nullable id<NSCopying>)key;

@end

NS_ASSUME_NONNULL_END
