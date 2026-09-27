//
//  EqualizerIndicatorView+Debug.h
//  Vibe
//
//  Process-wide renderer counters for dump_equalizer. Implemented beside the
//  view, whose hot paths increment them as relaxed atomics.
//

#if DEBUG

#import "EqualizerIndicatorView.h"

@interface EqualizerIndicatorView (Debug)

+ (uint64_t)vibeDebugActiveDisplayLinkCount;
+ (uint64_t)vibeDebugTotalDisplayTickCount;
+ (uint64_t)vibeDebugTotalGeometryLayoutCount;
+ (uint64_t)vibeDebugTotalTransformWriteCount;

@end

#endif
