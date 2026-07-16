//
// Created by Christopher Micali on 12/27/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#define StateForBOOL(b) ((b) ? NSControlStateValueOn : NSControlStateValueOff)
#define StateForString(s1, s2) StateForBOOL([s1 isEqualToString:s2])

// Note: no lowercase min()/max() macros — they shadow std::min/std::max in the
// ObjC++ (.mm) translation units this prefix header reaches. Use MIN/MAX.

// A function, not a macro, so the arguments are evaluated once. Plain C (no
// templates/overloads) — this header reaches every ObjC (.m) translation
// unit via the prefix header.
static inline double clampMin(double v, double minValue) {
    return v < minValue ? minValue : v;
}

#define run_on_main_thread(block) dispatch_async(dispatch_get_main_queue(), ^(void)block)
