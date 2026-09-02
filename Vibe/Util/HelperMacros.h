//
//  HelperMacros.h
//  Vibe
//

#include <TargetConditionals.h>

#if TARGET_OS_OSX
#define StateForBOOL(b) ((b) ? NSControlStateValueOn : NSControlStateValueOff)
#endif

// Note that there are no lowercase min() or max() macros: they would shadow
// std::min and std::max in the ObjC++ (.mm) translation units this prefix
// header reaches. Use MIN and MAX.

// A function rather than a macro, so the arguments are evaluated once. It is
// plain C, with no templates or overloads, because this header reaches every
// ObjC (.m) translation unit through the prefix header.
static inline double clampMin(double v, double minValue) {
    return v < minValue ? minValue : v;
}

// A macro, not a function, so the integer sites (bar counts, indexes) and the
// floating ones share one clamp without a conversion; MIN and MAX already
// evaluate each argument exactly once.
#define clampRange(v, lo, hi) MIN(MAX((v), (lo)), (hi))

#define run_on_main_thread(block) dispatch_async(dispatch_get_main_queue(), ^(void)block)
