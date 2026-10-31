//
//  DebugFrameProbe.m
//  vibe-libs
//

#import "DebugFrameProbe.h"

#if DEBUG

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import "VibeMacros.h"

// The frame-rate probe: a display link counting the frames the app is
// granted and how often one ran long. The answer to "is this 60 or 120, and
// does it hitch" that the simulator cannot give. Process-wide: it needs no
// controller, and a phone starts it from a launch flag before there is one.
static CADisplayLink *sFrameProbe;
static CFTimeInterval sFrameProbeStartedAt;
static CFTimeInterval sFrameProbeLastAt;
static CFTimeInterval sFrameProbeEndsAt;
static CFTimeInterval sFrameProbeWorstInterval;
static NSUInteger sFrameProbeFrames;
static NSUInteger sFrameProbeHitches;

static void VibeFrameProbeResetWindow(CFTimeInterval now) {
    sFrameProbeStartedAt = now;
    sFrameProbeLastAt = 0;
    sFrameProbeWorstInterval = 0;
    sFrameProbeFrames = 0;
    sFrameProbeHitches = 0;
}

// The display link's target. A display link retains its target, so the probe
// holds no object of the app's.
@interface VibeDebugFrameProbeTarget : NSObject
@end

@implementation VibeDebugFrameProbeTarget

- (void)probeFrame:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    if (sFrameProbeLastAt > 0) {
        CFTimeInterval interval = now - sFrameProbeLastAt;
        sFrameProbeWorstInterval = MAX(sFrameProbeWorstInterval, interval);
        // A frame that took two of the granted periods or more.
        if (interval >= 2 * (link.targetTimestamp - now) + 0.001) {
            sFrameProbeHitches++;
        }
    }
    sFrameProbeLastAt = now;
    sFrameProbeFrames++;
    // The continuous probe — the launch flag's — logs a window every five
    // seconds, which the device console relays off a phone (OS_ACTIVITY_DT_MODE).
    if (sFrameProbeEndsAt == 0 && now - sFrameProbeStartedAt >= 5) {
        NSDictionary *report = VibeDebugFrameProbeReport();
        LogInfo(@"Frame probe: %@ Hz over %@ s, %@ hitches, worst %@ ms",
                report[@"averageHz"], report[@"seconds"], report[@"hitches"], report[@"worstIntervalMs"]);
        VibeFrameProbeResetWindow(now);
    }
    else if (sFrameProbeEndsAt > 0 && now >= sFrameProbeEndsAt) {
        [link invalidate];
        sFrameProbe = nil;
    }
}

@end

void VibeDebugBeginFrameProbe(NSTimeInterval seconds) {
    [sFrameProbe invalidate];
    CFTimeInterval now = CACurrentMediaTime();
    VibeFrameProbeResetWindow(now);
    sFrameProbeEndsAt = seconds > 0 ? now + seconds : 0;
    // On the main run loop, riding whatever rate the app's own work earns:
    // the probe measures, it must not ask.
    sFrameProbe = [CADisplayLink displayLinkWithTarget:[VibeDebugFrameProbeTarget new]
                                              selector:@selector(probeFrame:)];
    [sFrameProbe addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

NSDictionary *VibeDebugFrameProbeReport(void) {
    CFTimeInterval seconds = (sFrameProbeLastAt ?: CACurrentMediaTime()) - sFrameProbeStartedAt;
    double hz = seconds > 0 && sFrameProbeFrames > 1 ? (sFrameProbeFrames - 1) / seconds : 0;
    // 120 only when the app may draw at it: an iPhone caps an app at 60
    // without CADisableMinimumFrameDurationOnPhone.
    UIScreen *screen = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            screen = ((UIWindowScene *)scene).screen;
            break;
        }
    }
    return @{@"frames": @(sFrameProbeFrames),
             @"seconds": @(round(seconds * 100) / 100),
             @"averageHz": @(round(hz * 10) / 10),
             @"hitches": @(sFrameProbeHitches),
             @"worstIntervalMs": @(round(sFrameProbeWorstInterval * 10000) / 10),
             @"maximumHz": @(screen ? screen.maximumFramesPerSecond : 0)};
}

#endif
