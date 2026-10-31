//
//  DebugFrameProbe.h
//  vibe-libs
//
//  The display-link frame probe behind sample_frame_rate and dump_frame_rate:
//  the frames the app is granted, and how many ran long.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Starts a fresh window, replacing any probe running. seconds of 0 runs until
// replaced and logs a report every five seconds, the device's road, since the
// device console (OS_ACTIVITY_DT_MODE) is all a phone offers.
void VibeDebugBeginFrameProbe(NSTimeInterval seconds);

// The current window's frames, seconds, average and maximum rates, hitches,
// and worst interval.
NSDictionary *VibeDebugFrameProbeReport(void);

NS_ASSUME_NONNULL_END
