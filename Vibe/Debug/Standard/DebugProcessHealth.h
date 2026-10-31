//
//  DebugProcessHealth.h
//  vibe-libs
//
//  The process counters behind dump_health, on both platforms. Every count is
//  for diffing between two readings of a run. None means much alone.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

// dump_health's "process" block: the memory footprint, the resident and
// malloc bytes, the threads, the open file descriptors, the mach ports, and
// the uptime.
NSDictionary<NSString *, NSNumber *> *VibeDebugProcessHealth(void);

// Live allocations and the allocator's reservations, apart. Live bytes tell a
// retained object from a freed page the allocator still holds.
void VibeDebugMallocBytes(uint64_t *live, uint64_t *reserved);

// Layers under and including layer.
NSUInteger VibeDebugLayerCount(CALayer *layer);

NS_ASSUME_NONNULL_END
