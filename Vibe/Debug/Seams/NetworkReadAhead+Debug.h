//
//  NetworkReadAhead+Debug.h
//  Vibe
//
//  The read-ahead's own test hooks: which files read ahead, and what each of
//  its reads does. Both are process-wide. The statics and the functions live
//  in NetworkReadAhead.m. AudioFileHandle (Debug) forwards to them, and its
//  header states each one's contract.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void VibeNetworkReadAheadDebugSetMountRule(NSNumber *_Nullable (^_Nullable rule)(NSURL *url));
void VibeNetworkReadAheadDebugSetBeforeRead(int (^_Nullable beforeRead)(NSURL *url, uint64_t offset, uint64_t length));
void VibeNetworkReadAheadDebugSetRetryScale(double scale);
NSInteger VibeNetworkReadAheadDebugLive(void);
NSInteger VibeNetworkReadAheadDebugOrphaned(void);

NS_ASSUME_NONNULL_END
