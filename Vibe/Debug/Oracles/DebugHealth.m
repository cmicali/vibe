//
//  DebugHealth.m
//  Vibe
//

#import "DebugHealth.h"

#if DEBUG

#import <malloc/malloc.h>
#import "DebugProcessHealth.h"
#import "DebugWireFormat.h"
#import "AudioPlayer+Debug.h"
#import "AudioFileMaterializationCoordinator+Debug.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioTrackMetadataCache+Debug.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "AudioTrackMetadataCache.h"
#import "AudioPlayer.h"

#pragma mark - Pending work

// App-owned work that must return to zero at rest; VibeIsSettled scores
// every entry, so whatever holds out names itself. The containers are leak
// signals too small for the process counters to see; the in-flight gauges
// name work stuck below them. engineCounts comes from the caller so the
// player's queue is crossed once per dump. The surface adds its platform's
// own (the mac's open funnel).
static NSDictionary<NSString *, NSNumber *> *VibePendingCounts(id<VibeDebugPlayerSurface> surface,
                                                              NSDictionary *engineCounts) {
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
    AudioTrackMetadataCache *metadataCache = [surface debugMetadataCache];
    // Each source reports in its own vocabulary; the schema's names are set here.
    NSDictionary<NSString *, NSNumber *> *parse = [metadataCache.parseCoordinator pendingCounts];
    out[@"metadataHolders"] = parse[@"holders"];
    out[@"metadataWaiters"] = parse[@"waiters"];
    if ([surface respondsToSelector:@selector(debugPendingCounts)]) {
        [out addEntriesFromDictionary:[surface debugPendingCounts]];
    }
    out[@"retiredFades"] = engineCounts[@"retiredFades"];
    // A queued cloud parse that never ran is a row stuck on its filename
    // forever. A lane still held at rest is the whole sweep suspended: the
    // hold is set when a slow open starts and cleared when it settles, so a
    // teardown that loses the clearing edge shows up here and nowhere else.
    out[@"cloudParsesPending"] = @([metadataCache debugPendingBackgroundMaterializationCount]);
    out[@"cloudLaneHeld"] = @([metadataCache debugBackgroundMaterializationHeld] ? 1 : 0);
    // A priority record outliving its play is a strand no other counter shows.
    out[@"priorityRecordsPending"] =
            @([(NSArray *)[metadataCache debugPriorityLaneState][@"pending"] count]);
    // Counted from before the scheduler/worker handoff, so a probe outliving
    // the claim whose last waiter detached never reads zero in between. At
    // rest it separates stuck classification from transfer or open work.
    out[@"datalessProbesInFlight"] =
            @([AudioFileMaterializationCoordinator.sharedCoordinator
                    datalessProbesInFlight]);
    // Outstanding handle opens retain admission capacity until they return.
    // Read lock-free because quiesce polls this every 100ms.
    out[@"handleOpensInFlight"] =
            @([AudioFileMaterializationCoordinator.sharedCoordinator handleOpensInFlight]);
    return out;
}

#pragma mark - dump_health

NSDictionary *VibeDebugHealthExtras(id<VibeDebugPlayerSurface> surface) {
    AudioPlayer *player = [surface debugPlayer];

    // Blocks on the player's serial queue, so a wedged queue times the command
    // out rather than letting it answer from stale state.
    NSDictionary *counts = [player debugRenderCounts];

    NSMutableDictionary *app = [@{
            @"playlistCount": @([surface debugPlaylistCount]),
            @"currentIndex": @([surface debugPlaylistCurrentIndex]),
            @"playerLoading": @(player.isLoading),
            @"gaplessArmed": @(player.isGaplessArmed),
            // Warm every effect before comparing against a leak baseline.
            @"hostedUnits": counts[@"hostedUnits"],
            // The bus's drain timer: on only while the output runs voices, so
            // 1 at rest is a wakeup the idle guarantee forbids.
            @"drainPolling": counts[@"pollActive"],
            // IO cycles the hosted output unit wrote as silence because the
            // pipeline failed to render; cumulative, and a soak holds it at 0.
            @"outputDropouts": counts[@"outputDropouts"],
            // Renders the pipeline turned away because a stuck one was still
            // inside when the next output unit's callback came; cumulative, 0.
            @"renderRefusals": counts[@"renderRefusals"],
            // The output unit's callback cost over the cycles it rendered:
            // cumulative, so diff across a run, and mean against max.
            @"renderCycles": counts[@"renderCycles"],
            @"renderMeanMicros": counts[@"renderMeanMicros"],
            @"renderMaxMicros": counts[@"renderMaxMicros"],
    } mutableCopy];
    if ([surface respondsToSelector:@selector(debugHealthApp)]) {
        [app addEntriesFromDictionary:[surface debugHealthApp]];
    }
    return @{
        @"ui": [surface debugHealthUI],
        @"app": app,
        @"pending": VibePendingCounts(surface, counts),
        // Diagnosis, not scoring: the lane gauges and the cumulative outcome
        // counters that say whether work is still being *attempted*. The one
        // number here that belongs at zero at rest is already in `pending`.
        @"materialization":
                [AudioFileMaterializationCoordinator.sharedCoordinator debugState],
    };
}

#pragma mark - quiesce

static const NSTimeInterval kQuiesceDeadline = 15.0;
static const NSTimeInterval kQuiescePollInterval = 0.1;

static BOOL VibeIsSettled(id<VibeDebugPlayerSurface> surface, NSDictionary *pending) {
    for (NSNumber *count in pending.objectEnumerator) {
        if (count.unsignedIntegerValue > 0) {
            return NO;
        }
    }
    AudioPlayer *player = [surface debugPlayer];
    return player.isStopped && !player.isLoading;
}

void VibeDebugQuiesce(id<VibeDebugPlayerSurface> surface, void (^completion)(NSString *)) {
    // Close is the whole teardown; quiescing is that plus waiting for what it
    // cancelled to unwind.
    [surface debugCloseFile];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kQuiesceDeadline];
    __block NSDate *started = [NSDate date];
    __block void (^poll)(void);
    __weak id<VibeDebugPlayerSurface> weakSurface = surface;
    poll = ^{
        id<VibeDebugPlayerSurface> strong = weakSurface;
        if (!strong) {
            completion(VibeJSONString(@{@"error": @"controller went away"}));
            poll = nil;
            return;
        }
        NSDictionary *pending = VibePendingCounts(strong, [[strong debugPlayer] debugRenderCounts]);
        BOOL settled = VibeIsSettled(strong, pending);
        if (!settled && [deadline timeIntervalSinceNow] > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQuiescePollInterval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), poll);
            return;
        }
        // Hand every zone's free pages back before the caller samples, or
        // phys_footprint reports the allocator's high-water mark and a freed
        // decode buffer reads as a leak that never comes down. releasedBytes
        // is reported because the call is not reliably effective: it can
        // return nothing while MALLOC_LARGE regions still hold dirty pages
        // with no live allocations.
        uint64_t liveBefore = 0, reservedBefore = 0;
        VibeDebugMallocBytes(&liveBefore, &reservedBefore);
        size_t released = malloc_zone_pressure_relief(NULL, 0);
        uint64_t liveAfter = 0, reservedAfter = 0;
        VibeDebugMallocBytes(&liveAfter, &reservedAfter);
        // Reported rather than treated as an error: work that will not unwind
        // within the deadline is itself the finding, and the caller can see
        // which counter held out.
        completion(VibeJSONString(@{
            @"ok": @YES,
            @"settled": @(settled),
            @"waitedSeconds": @(-[started timeIntervalSinceNow]),
            @"pending": pending,
            @"pressureRelief": @{
                @"releasedBytes": @(released),
                @"mallocLiveBytes": @(liveAfter),
                @"mallocReservedBytes": @(reservedAfter),
                @"reservedFreedBytes": @(reservedBefore > reservedAfter
                                         ? reservedBefore - reservedAfter : 0),
            },
        }));
        poll = nil;
    };
    poll();
}

#endif
