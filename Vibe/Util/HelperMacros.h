//
// Created by Christopher Micali on 12/27/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#define StateForBOOL(b) ((b) ? NSControlStateValueOn : NSControlStateValueOff)
#define StateForString(s1, s2) StateForBOOL([s1 isEqualToString:s2])

#define BOOLToStr(b) (b?@"Yes":@"No")

#define min(a, b) (b < a ? b : a)
#define max(a, b) (a < b ? b : a)

// #define clampMax(v, max) (v > max ? max : v)
#define clampMin(v, min) (v < min ? min : v)
// #define clamp(v, min, max) clampMin(clampMax(v, max), min)

#define TIME_START(msg) CFTimeInterval startTime = CACurrentMediaTime(); CFTimeInterval endTime; NSString *timer_msg = msg;
#define TIME_RESTART(msg) startTime = CACurrentMediaTime(); timer_msg = msg;
#define TIME_END endTime = CACurrentMediaTime(); LogDebug(@"%@ time: %1.4f s", timer_msg, endTime - startTime);

#define AlignSizeToTypeBoundary(size, type) { if (size % sizeof(type) != 0) { size += sizeof(type) - size % sizeof(type); } }

#define run_on_main_thread(block) dispatch_async(dispatch_get_main_queue(), ^(void)block)

#define round_to_precision(val, precision) (double)(((NSInteger)(val*((double)pow(10,precision))))/pow(10,precision))
