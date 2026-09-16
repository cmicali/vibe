//
//  FolderArtEntry.h
//  Vibe
//
//  Everything the folder-art resolver knows about ONE directory, in one
//  object, which is what makes eviction and both invalidations a single pass
//  over a single dictionary. It has no behavior beyond three derived
//  predicates: the resolver owns every transition.
//
//  Mutated only under the resolver's lock, hence nonatomic throughout.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FolderArtEntry : NSObject

// The cover's full path, kNoArtMarker for "settled, it has none", or nil for
// "not looked at yet".
@property (nonatomic, copy, nullable) NSString *artPath;
// Unique for the resolver's lifetime, 0 for none assigned. It fences both
// discovery and decode, same-path replacement races included.
@property (nonatomic) uint64_t answerGeneration;
// The answerGeneration of the resolve claim currently held, or 0 for none.
@property (nonatomic) uint64_t resolving;
// Decodes in flight that hold no resolve claim — the settled fast path in
// displayImageForAudioFilePath:.
@property (nonatomic) NSUInteger decoding;
// A background resolve is dispatched but has not reached the queue.
@property (nonatomic) BOOL scheduled;
@property (nonatomic) uint64_t lastAccess;
// Settled as artless only because the app held no grant for the folder. These
// are the only answers a grant change may clear.
@property (nonatomic) BOOL settledWithoutGrant;
// A cover path is known, but its security scope is no longer active. Keep the
// donated path so a later grant can resume without demoting it to stat probes,
// while preventing every redraw from retrying the forbidden read.
@property (nonatomic) BOOL readBlockedWithoutGrant;
// The folder came from a bulk open, so one listing beats the lone file's stat
// probes. A fact about how the user opened it rather than a cached answer, so
// it survives an invalidate.
@property (nonatomic) BOOL preferListing;
@property (nonatomic) uint8_t readFailures;

// The folder has an answer, either way.
@property (nonatomic, readonly) BOOL settled;
// The answer is "there is no cover here".
@property (nonatomic, readonly) BOOL settledEmpty;
// Work in flight checks this entry's answerGeneration when it lands, so eviction has
// to leave it alone or it throws that work away.
@property (nonatomic, readonly) BOOL busy;

// Drops the answer, keeping the facts about how the folder was opened.
- (void)forgetSettledAnswer;

@end

NS_ASSUME_NONNULL_END
