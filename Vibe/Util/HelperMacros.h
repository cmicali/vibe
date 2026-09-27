//
//  HelperMacros.h
//  Vibe
//

#include <TargetConditionals.h>

#if TARGET_OS_OSX
#define StateForBOOL(b) ((b) ? NSControlStateValueOn : NSControlStateValueOff)
#endif

// No lowercase min()/max(): they would shadow std::min/std::max in the .mm
// files the prefix header reaches. Use MIN and MAX.

static inline double clampMin(double v, double minValue) {
    return v < minValue ? minValue : v;
}

// A macro, so integer and floating sites share it without conversion; MIN and
// MAX evaluate each argument once.
#define clampRange(v, lo, hi) MIN(MAX((v), (lo)), (hi))

#define run_on_main_thread(block) dispatch_async(dispatch_get_main_queue(), ^(void)block)
