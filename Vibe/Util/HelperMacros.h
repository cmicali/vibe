//
// Created by Christopher Micali on 12/27/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#include <TargetConditionals.h>

#if TARGET_OS_OSX
#define StateForBOOL(b) ((b) ? NSControlStateValueOn : NSControlStateValueOff)
#define StateForString(s1, s2) StateForBOOL([s1 isEqualToString:s2])
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

#define run_on_main_thread(block) dispatch_async(dispatch_get_main_queue(), ^(void)block)
