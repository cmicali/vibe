//
//  EqualizerIndicatorView+Debug.h
//  Vibe
//
//  Process-wide renderer counters for dump_levels. The implementation stays
//  beside the view so its hot paths can increment relaxed atomics directly;
//  this declaration lives in Debug so the shipping view API stays minimal.
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
