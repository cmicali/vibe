//
//  ServedFileHandle.h
//  Vibe
//
//  What the coordinator needs of a handle its opener returns (stage 2). The
//  loader never names the handle's class: the caller's opener makes it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ServedFileHandle <NSObject>

// Once, on the opening thread before the handle is shared: makes it one of
// its transfer's readers until dealloc (CloudFileAvailability's addReader),
// which keeps the transfer from being abandoned. The coordinator sends it to
// every handle it serves. A handle that reads no stream ignores it.
- (void)holdStream;

@end

NS_ASSUME_NONNULL_END
