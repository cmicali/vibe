//
//  OpenRequestCoordinator+Debug.h
//  Vibe
//
//  Implemented beside the coordinator, whose buffer is private to it.
//

#import "OpenRequestCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface OpenRequestCoordinator (Debug)
// Results finished but buffered behind an earlier request. Zero after every
// burst; a floor that creeps upward is a delivery that never happened. Main
// thread.
- (NSUInteger)debugBufferedResultCount;
@end

NS_ASSUME_NONNULL_END
