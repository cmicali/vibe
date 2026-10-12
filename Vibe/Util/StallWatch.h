//
//  StallWatch.h
//  Vibe
//
//  The beta stall log's watchdogs and stack sampler. They read no player
//  state. Everything but the scene flag exists only under
//  VIBE_VERBOSE_LOGGING.
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

// Whether the app's scene is foreground-active, for the stall log: iOS makes
// an app that has just left the screen redraw itself for the app-switcher
// snapshot, a main-thread stall of ~250 ms on device that the user never sees,
// so a stall while inactive says so. The iOS shell reports its scene; macOS
// never calls it. Main thread.
void VibeStallWatchNoteSceneActive(BOOL active);

#if VIBE_VERBOSE_LOGGING
// The main thread's watchdog, one per process. `thread` is its port, or
// MACH_PORT_NULL to find it at each sample.
void VibeWatchMainThreadForStalls(mach_port_t thread);
// A serial queue's watchdog, returned suspended.
dispatch_source_t VibeWatchQueueForStalls(dispatch_queue_t queue, NSString *name);
// The thread now draining queue, else the first whose pthread name is name.
// The caller owns a returned port.
thread_t VibeFindThread(dispatch_queue_t _Nullable queue, const char * _Nullable name);
// Logs one sample of thread's stack, unless it matches previous. Returns it.
NSString *VibeSampleStack(thread_t thread, NSString *name, double milliseconds, NSString * _Nullable previous);
#endif

NS_ASSUME_NONNULL_END
