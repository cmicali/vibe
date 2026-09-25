//
//  AudioPlayer+Diagnostics.m
//  Vibe
//
//  Audio-path reports in every build, and beta instrumentation under
//  VIBE_VERBOSE_LOGGING. performDiagnosticPhase: always runs its operation.
//

#import "AudioPlayer+Diagnostics.h"
#import "AudioPlayerInternal.h"
#import "AudioTrack.h"
#import "AudioFX.h"
#import <stdatomic.h>
#if DEBUG
#import "VibeManualRenderPump.h"
#endif

#if VIBE_VERBOSE_LOGGING
#if TARGET_OS_OSX
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <pthread.h>

// macOS gives user space 47 bits; anything above is a pointer-authentication
// signature on a return address saved by an arm64e system frame.
static const uintptr_t kVibeReturnAddressMask = 0x00007FFFFFFFFFFFULL;

// A stack of any depth keeps its first and last kVibeStackEnd frames: where
// the thread is stuck, and how it got there (main, the run loop, and the Vibe
// code that started the work). The log then trims the middle further.
static const int kVibeStackEnd = 512;
static const NSUInteger kVibeStackHeadFrames = 40, kVibeStackTailFrames = 60;

static void VibeReverse(uintptr_t *a, int n) {
    for (int i = 0, j = n - 1; i < j; i++, j--) {
        uintptr_t t = a[i]; a[i] = a[j]; a[j] = t;
    }
}

// Walks a thread's whole frame-pointer chain into pcs (2 * kVibeStackEnd
// entries): the first kVibeStackEnd return addresses, then the last
// kVibeStackEnd in order, kept in a ring while walking. Returns the chain's full
// length; min(length, 2 * kVibeStackEnd) entries are stored.
// TRAP: between suspend and resume nothing may allocate or take any lock the
// stalled thread might hold — malloc's included — so this is C and system
// calls only, the reads go through vm_read_overwrite so a bad frame ends the
// walk instead of faulting, and symbolication waits until after the resume.
static int VibeCaptureStack(thread_t thread, uintptr_t *pcs) {
    if (thread_suspend(thread) != KERN_SUCCESS) {
        return 0;
    }
    int count = 0;
#define VIBE_KEEP(pc) do { \
        int at = count < kVibeStackEnd ? count : kVibeStackEnd + (count - kVibeStackEnd) % kVibeStackEnd; \
        pcs[at] = (pc); count++; \
    } while (0)
    uintptr_t fp = 0;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
        VIBE_KEEP((uintptr_t)arm_thread_state64_get_pc(state) & kVibeReturnAddressMask);
        VIBE_KEEP((uintptr_t)arm_thread_state64_get_lr(state) & kVibeReturnAddressMask);
        fp = (uintptr_t)arm_thread_state64_get_fp(state);
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t stateCount = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
        VIBE_KEEP((uintptr_t)state.__rip);
        fp = (uintptr_t)state.__rbp;
    }
#endif
    // Terminates: every accepted frame pointer is strictly above the last.
    while (fp) {
        uintptr_t frame[2] = {0, 0};
        vm_size_t got = 0;
        if (vm_read_overwrite(mach_task_self(), fp, sizeof(frame), (vm_address_t)frame, &got) != KERN_SUCCESS
                || got != sizeof(frame)) {
            break;
        }
        uintptr_t returnAddress = frame[1] & kVibeReturnAddressMask;
        if (!returnAddress) {
            break;
        }
        VIBE_KEEP(returnAddress);
        if (frame[0] <= fp) {
            break; // a frame chain climbs the stack; anything else is corrupt
        }
        fp = frame[0];
    }
#undef VIBE_KEEP
    thread_resume(thread);
    if (count > 2 * kVibeStackEnd) {
        // Rotate the ring so its oldest entry comes first.
        int oldest = (count - kVibeStackEnd) % kVibeStackEnd;
        uintptr_t *ring = pcs + kVibeStackEnd;
        VibeReverse(ring, oldest);
        VibeReverse(ring + oldest, kVibeStackEnd - oldest);
        VibeReverse(ring, kVibeStackEnd);
    }
    return count;
}

// Symbols for the system's frames; Vibe's own (image 0, the executable) are
// stripped in a release, so they print as offsets into the binary, to
// symbolicate against the archived dSYM for the build the report names. A
// run of one frame collapses to one entry: a recursive layout pass repeats its
// call site dozens of times and would otherwise crowd out the frames that
// started it, which is where Vibe's own code appears.
static NSArray<NSString *> *VibeDescribeStack(const uintptr_t *pcs, int length) {
    NSMutableArray<NSString *> *frames = [NSMutableArray array];
    NSString *previous = nil;
    NSUInteger repeats = 0;
    int count = MIN(length, 2 * kVibeStackEnd);
    for (int i = 0; i <= count; i++) {
        BOOL gap = i == kVibeStackEnd && length > count; // the walk kept no frames here
        NSString *frame = nil;
        if (i < count) {
            uintptr_t pc = i == 0 ? pcs[i] : pcs[i] - 1; // a return address points after its call
            Dl_info info;
            if (!dladdr((const void *)pc, &info) || !info.dli_fname) {
                frame = [NSString stringWithFormat:@"0x%lx", (unsigned long)pc];
            } else if (info.dli_fbase == (const void *)_dyld_get_image_header(0) || !info.dli_sname) {
                frame = [NSString stringWithFormat:@"%@ +0x%lx", @(info.dli_fname).lastPathComponent,
                         (unsigned long)(pc - (uintptr_t)info.dli_fbase)];
            } else {
                frame = [NSString stringWithFormat:@"%@ %s+%lu", @(info.dli_fname).lastPathComponent,
                         info.dli_sname, (unsigned long)(pc - (uintptr_t)info.dli_saddr)];
            }
            if (frame.length > 240) {
                frame = [[frame substringToIndex:239] stringByAppendingString:@"~"]; // one C++ symbol can fill a line
            }
            if (!gap && [frame isEqualToString:previous]) {
                repeats++;
                continue;
            }
        }
        if (previous) {
            [frames addObject:repeats ? [NSString stringWithFormat:@"%@ x%lu", previous, (unsigned long)repeats + 1]
                                      : previous];
        }
        if (gap) {
            [frames addObject:[NSString stringWithFormat:@"... %d frames not kept ...", length - count]];
        }
        previous = frame;
        repeats = 0;
    }
    // Where it is stuck is at the top and how it got there, Vibe's frames
    // included, near the bottom; a recursion that alternates frames does not
    // collapse, so bound the middle rather than either end.
    if (frames.count > kVibeStackHeadFrames + kVibeStackTailFrames + 1) {
        NSRange middle = NSMakeRange(kVibeStackHeadFrames,
                                     frames.count - kVibeStackHeadFrames - kVibeStackTailFrames);
        [frames replaceObjectsInRange:middle withObjectsFromArray:@[
            [NSString stringWithFormat:@"... %lu frames omitted ...", (unsigned long)middle.length]]];
    }
    return frames;
}

// The thread now draining queue — THREAD_IDENTIFIER_INFO names the queue each
// pool thread is serving, which is how crash reports label threads — else the
// first whose pthread name is name. MACH_PORT_NULL when none; the caller owns
// a returned port. Reads only, so nothing here can stall the thread it finds.
static thread_t VibeFindThread(dispatch_queue_t queue, const char *name) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
        return MACH_PORT_NULL;
    }
    thread_t me = mach_thread_self(), found = MACH_PORT_NULL;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_t thread = threads[i];
        if (found == MACH_PORT_NULL && thread != me) {
            if (queue) {
                thread_identifier_info_data_t info;
                mach_msg_type_number_t infoCount = THREAD_IDENTIFIER_INFO_COUNT;
                uintptr_t serving = 0;
                vm_size_t got = 0;
                if (thread_info(thread, THREAD_IDENTIFIER_INFO, (thread_info_t)&info, &infoCount) == KERN_SUCCESS
                        && info.dispatch_qaddr
                        && vm_read_overwrite(mach_task_self(), (vm_address_t)info.dispatch_qaddr, sizeof(serving),
                                             (vm_address_t)&serving, &got) == KERN_SUCCESS
                        && got == sizeof(serving) && serving == (uintptr_t)(__bridge void *)queue) {
                    found = thread;
                }
            }
            else {
                thread_extended_info_data_t info;
                mach_msg_type_number_t infoCount = THREAD_EXTENDED_INFO_COUNT;
                if (thread_info(thread, THREAD_EXTENDED_INFO, (thread_info_t)&info, &infoCount) == KERN_SUCCESS
                        && strcmp(info.pth_name, name) == 0) {
                    found = thread;
                }
            }
        }
        if (thread != found) {
            mach_port_deallocate(mach_task_self(), thread);
        }
    }
    mach_port_deallocate(mach_task_self(), me);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    return found;
}

// TRAP: the unified log truncates one message near 1 KB (it ends "<…>"), which
// cut the first beta stacks off before any of Vibe's frames. Numbered lines.
static void VibeLogStack(NSString *name, double milliseconds, NSArray<NSString *> *frames) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableString *line = [NSMutableString string];
    for (NSString *frame in frames) {
        if (line.length && line.length + frame.length + 3 > 800) {
            [lines addObject:line];
            line = [NSMutableString string];
        }
        [line appendString:line.length ? [@" | " stringByAppendingString:frame] : frame];
    }
    if (line.length) {
        [lines addObject:line];
    }
    for (NSUInteger i = 0; i < lines.count; i++) {
        LogWarn(@"Stall stack: the %@, %.0f ms in (%lu/%lu): %@", name, milliseconds,
                (unsigned long)i + 1, (unsigned long)lines.count, lines[i]);
    }
}

// One sample, logged in full unless it matches the previous sample of the same
// stall. Returns it, for the next comparison.
static NSString *VibeSampleStack(thread_t thread, NSString *name, double milliseconds, NSString *previous) {
    uintptr_t pcs[2 * kVibeStackEnd]; // 8 KB; the watchers run on pool threads, never the stalled one
    NSArray<NSString *> *frames = VibeDescribeStack(pcs, VibeCaptureStack(thread, pcs));
    NSString *stack = [frames componentsJoinedByString:@" | "];
    if ([stack isEqualToString:previous]) {
        LogWarn(@"Stall stack: the %@, %.0f ms in: unchanged", name, milliseconds);
    }
    else {
        VibeLogStack(name, milliseconds, frames);
    }
    return stack;
}
#endif

// One stall's samples: 250 ms in, then every 500 ms — a long freeze can move
// between causes, and a single sample would show only the first — six at
// most, the onset logged at the first. `samples` and `nextSampleAt` are the
// caller's, zeroed for each new stall.
static BOOL VibeStallSampleDue(NSString *name, uint64_t stuck, int *samples, uint64_t *nextSampleAt) {
    if (stuck <= 250 * NSEC_PER_MSEC || stuck < *nextSampleAt || *samples >= 6) {
        return NO;
    }
    if (!*samples) {
        LogWarn(@"Stall: the %@ is still blocked after %.0f ms", name, stuck / 1e6);
    }
    (*samples)++;
    *nextSampleAt = stuck + 500 * NSEC_PER_MSEC;
    return YES;
}

// A queue that takes more than 200 ms to run an empty block was blocked by
// something, and the log says for how long, so a reported freeze can be told
// apart from late audio; a stuck queue is sampled through whichever pool
// thread is draining it. Returned suspended: the player resumes it while it
// has work that can stall (refreshQueueStallWatcherOnQueue).
static dispatch_source_t VibeWatchQueueForStalls(dispatch_queue_t queue, NSString *name) {
    dispatch_queue_t watcher = dispatch_queue_create("com.vibe.stallwatch", DISPATCH_QUEUE_SERIAL);
    __block BOOL waiting = NO; // confined to watcher, like the rest below
    __block uint64_t pingedAt = 0;
    __block int samples = 0;
    __block uint64_t nextSampleAt = 0;
    __block NSString *lastStack = nil;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watcher);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (waiting) {
            uint64_t stuck = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - pingedAt;
            if (VibeStallSampleDue(name, stuck, &samples, &nextSampleAt)) {
#if TARGET_OS_OSX
                // The queue has no fixed thread: find the one draining it.
                // None means it is queued but starved.
                thread_t thread = VibeFindThread(queue, NULL);
                if (thread == MACH_PORT_NULL) {
                    LogWarn(@"Stall stack: the %@, %.0f ms in: no thread is running it", name, stuck / 1e6);
                }
                else {
                    lastStack = VibeSampleStack(thread, name, stuck / 1e6, lastStack);
                    mach_port_deallocate(mach_task_self(), thread);
                }
#endif
            }
            return; // the ping's delivery reports recovery
        }
        waiting = YES;
        samples = 0;
        nextSampleAt = 0;
        lastStack = nil;
        uint64_t sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        pingedAt = sent;
        dispatch_async(queue, ^{
            uint64_t waited = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - sent;
            dispatch_async(watcher, ^{
                waiting = NO;
            });
            if (waited > 200 * NSEC_PER_MSEC) {
                LogWarn(@"Stall: the %@ could not run anything for %.0f ms", name, waited / 1e6);
            }
        });
    });
    return timer;
}

// The main thread is watched by its run loop, not by pings. Each pass stamps
// its start — at BeforeSources, and at AfterWaiting for the wakeup's own
// work: the main queue's blocks, a timer, an event — and the loop's wait
// clears it, so a stall is a pass older than 250 ms, and a pass that ran
// long logs its own length as it ends. The watchdog that samples a stall
// runs only while passes happen: a pass arms it, a quiet period parks it, so
// an idle app wakes nothing and a stall is sampled whether or not the player
// is busy. A nested loop (a modal panel, event tracking) stamps and clears
// like the outer one, and a poll (a zero timeout) skips the wait's
// observers but not the pass's, so a loop pumped from a computation reads as
// responsive. One per process, like the thread it watches; `thread` is its
// port, read on it, or MACH_PORT_NULL to find it at each sample.
static void VibeWatchMainThreadForStalls(mach_port_t thread) {
    static _Atomic uint64_t passStart; // uptime nanos; 0 while the loop waits
    static _Atomic uint64_t passes;
    static _Atomic bool armed;
    const uint64_t period = 250 * NSEC_PER_MSEC;
    dispatch_queue_t watcher = dispatch_queue_create("com.vibe.stallwatch", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watcher);
    dispatch_block_t arm = ^{
        if (!atomic_exchange_explicit(&armed, true, memory_order_seq_cst)) {
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)period), period, 50 * NSEC_PER_MSEC);
        }
    };
    __block uint64_t lastPasses = 0, stalledPass = 0, nextSampleAt = 0; // confined to watcher
    __block int samples = 0;
    __block NSString *lastStack = nil;
    dispatch_source_set_event_handler(timer, ^{
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        uint64_t seen = atomic_load_explicit(&passes, memory_order_seq_cst);
        uint64_t since = atomic_load_explicit(&passStart, memory_order_seq_cst);
        if (since != stalledPass) {
            stalledPass = since;
            samples = 0;
            nextSampleAt = 0;
            lastStack = nil;
        }
        if (since && VibeStallSampleDue(@"main thread", now - since, &samples, &nextSampleAt)) {
#if TARGET_OS_OSX
            thread_t target = thread != MACH_PORT_NULL ? thread : VibeFindThread(dispatch_get_main_queue(), NULL);
            if (target != MACH_PORT_NULL) {
                lastStack = VibeSampleStack(target, @"main thread", (now - since) / 1e6, lastStack);
                if (target != thread) {
                    mach_port_deallocate(mach_task_self(), target);
                }
            }
#endif
        }
        if (!since && seen == lastPasses) {
            // Nothing ran since the last tick: park. The timer parks before
            // the flag clears, so a pass arming in between sets it after the
            // park; and the flag clears before the recheck, so a pass that
            // began between the read and the clear is armed for here.
            dispatch_source_set_timer(timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
            atomic_store_explicit(&armed, false, memory_order_seq_cst);
            if (atomic_load_explicit(&passes, memory_order_seq_cst) != seen) {
                arm();
            }
        }
        lastPasses = seen;
    });
    dispatch_source_set_timer(timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(timer);
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
            kCFRunLoopAfterWaiting | kCFRunLoopBeforeSources | kCFRunLoopBeforeWaiting, true, 0,
            ^(CFRunLoopObserverRef ref, CFRunLoopActivity activity) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        uint64_t previous = atomic_load_explicit(&passStart, memory_order_relaxed);
        if (previous && now - previous > 200 * NSEC_PER_MSEC) {
            LogWarn(@"Stall: the main thread could not run anything for %.0f ms", (now - previous) / 1e6);
        }
        if (activity == kCFRunLoopBeforeWaiting) {
            atomic_store_explicit(&passStart, 0, memory_order_seq_cst);
            return;
        }
        atomic_store_explicit(&passStart, now, memory_order_seq_cst);
        atomic_fetch_add_explicit(&passes, 1, memory_order_seq_cst);
        arm();
    });
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
}

static NSTimeInterval VibeMillisecondsSince(uint64_t nanos) {
    return (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - nanos) / 1e6;
}
#endif

@implementation AudioPlayer (Diagnostics)

#pragma mark - The path

static NSString *VibeCodecName(AudioFormatID format) {
    switch (format) {
        case kAudioFormatLinearPCM:     return @"PCM";
        case kAudioFormatFLAC:          return @"FLAC";
        case kAudioFormatAppleLossless: return @"ALAC";
        case kAudioFormatMPEG4AAC:      return @"AAC";
        case kAudioFormatMPEG4AAC_HE:
        case kAudioFormatMPEG4AAC_HE_V2: return @"HE-AAC";
        case kAudioFormatMPEGLayer3:    return @"MP3";
        case kAudioFormatMPEGLayer2:    return @"MP2";
        case kAudioFormatMPEGLayer1:    return @"MP1";
        default: {
            char text[5] = { (char)(format >> 24), (char)(format >> 16), (char)(format >> 8), (char)format, 0 };
            return [NSString stringWithFormat:@"%s", text];
        }
    }
}

static NSString *VibeSampleFormatName(AVAudioFormat *format) {
    switch (format.commonFormat) {
        case AVAudioPCMFormatInt16:   return @"int16";
        case AVAudioPCMFormatInt32:   return @"int32";
        case AVAudioPCMFormatFloat32: return @"float32";
        case AVAudioPCMFormatFloat64: return @"float64";
        default:                      return @"other";
    }
}

- (NSArray<NSDictionary<NSString *, id> *> *)audioPathOnQueue {
    NSArray *carrierPath = [self carrierAudioPathOnQueue];
    NSDictionary *renderFacts = [self pipelineRenderSnapshotOnQueue];
    AudioFileHandle *file = _file;
    NSMutableDictionary *source = [@{@"stage": @"source", @"present": @(file != nil)} mutableCopy];
    if (file) {
        const AudioStreamBasicDescription *asbd = file.fileFormat.streamDescription;
        source[@"file"] = file.url.lastPathComponent ?: @"";
        source[@"codec"] = VibeCodecName(asbd->mFormatID);
        source[@"lossless"] = @(asbd->mFormatID == kAudioFormatLinearPCM || asbd->mFormatID == kAudioFormatFLAC
                                || asbd->mFormatID == kAudioFormatAppleLossless);
        source[@"sampleRate"] = @(file.fileFormat.sampleRate);
        source[@"channels"] = @(file.fileFormat.channelCount);
        // The codec's declared depth: PCM's own, a lossless codec's
        // source-depth flags (OutputFormatRules.h), 0 for a lossy codec. Only
        // PCM's flags say float: a lossless codec's are its depth, and the
        // 24-bit one carries the float bit.
#if TARGET_OS_OSX
        source[@"bitsPerChannel"] = @(VibeSourceBitDepth(*asbd));
        source[@"float"] = @(VibeSourceIsFloat(*asbd));
#else
        source[@"bitsPerChannel"] = @(asbd->mBitsPerChannel);
        source[@"float"] = @(asbd->mFormatID == kAudioFormatLinearPCM && (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0);
#endif
        source[@"frames"] = @(file.length);
        source[@"decodedSampleFormat"] = VibeSampleFormatName(file.processingFormat);
    }

    // What the voice reads the file as, and how it gets there: direct, or
    // through the bus's converter (AudioVoiceBus.h).
    NSDictionary *conversion = [_voiceBus conversionOfVoice:_voice];
    AVAudioFormat *decodedFormat = _voice ? file.processingFormat : nil;
    NSMutableDictionary *decode = [@{@"stage": @"decode", @"present": @(_voice != 0 && decodedFormat != nil)} mutableCopy];
    if (decodedFormat) {
        decode[@"sampleFormat"] = VibeSampleFormatName(decodedFormat);
        decode[@"sampleRate"] = @(decodedFormat.sampleRate);
        decode[@"channels"] = @(decodedFormat.channelCount);
    }
    decode[@"read"] = conversion ? @"converted" : @"direct";
    [decode addEntriesFromDictionary:conversion ?: @{}];

    AudioVoiceBus *bus = _voiceBus;
    VibeVoiceSnapshot snapshot = [bus snapshotOfVoice:_voice];
    NSDictionary *busStage = @{
        @"stage": @"bus", @"present": @(bus != nil),
        @"sampleRate": @((bus.format ?: _masterFormat).sampleRate),
        @"channels": @((bus.format ?: _masterFormat).channelCount),
        @"sampleFormat": @"float32",
        @"liveVoices": @(bus.liveVoiceCount), @"occupiedSlots": @(bus.occupiedSlotCount),
        @"currentVoice": @(_voice), @"gain": @(snapshot.gain), @"consumedFrames": @(snapshot.consumed),
        @"underrunFrames": @(snapshot.underrunFrames), @"inlineDecoding": @(bus.inlineDecoding),
    };

    NSDictionary *varispeedStage = renderFacts[@"varispeed"];

    NSMutableDictionary *fx = [@{
        @"stage": @"fx", @"present": @(self.fx != nil), @"enabled": @(_fxEnabled), @"wanted": @([self fxWantedOnQueue]),
        @"inRender": renderFacts[@"fxInRender"],
    } mutableCopy];
    [fx addEntriesFromDictionary:self.fx.diagnosticSnapshot ?: @{}];

    NSDictionary *meter = @{
        @"stage": @"meter", @"present": @(_levelMeter != nil), @"installed": @(_levelMeter.installed),
        @"inRender": renderFacts[@"meterInRender"],
        @"wanted": @(_levelsWanted), @"probe": @(self.signalProbeWanted),
        @"sampleRate": @(_levelMeter.sampleRate), @"normalizationMode": @(_levelNormalizationMode),
    };

    NSMutableDictionary *output = [@{
        @"stage": @"output", @"present": @YES,
        @"sampleRate": @(_masterFormat.sampleRate), @"channels": @(_masterFormat.channelCount), @"sampleFormat": @"float32",
        @"running": @([self renderingOnQueue]),
        // Running with nothing to play: the deferred idle stop is pending.
        @"idleStopPending": @([self renderingOnQueue] && (_state == VibePlayerStateStopped || _state == VibePlayerStatePaused)),
        @"silent": renderFacts[@"silent"],
        @"framesRendered": renderFacts[@"framesRendered"],
    } mutableCopy];
#if DEBUG
    VibeManualRenderPump *pump = _manualPump;
    if (pump) {
        output[@"carrier"] = @"pump";
        output[@"automatic"] = @(pump.automatic);
    }
    else
#endif
    {
        [output addEntriesFromDictionary:carrierPath.firstObject];
    }

    NSMutableArray *stages = [NSMutableArray arrayWithObjects:source, decode, busStage, varispeedStage, fx, meter, output, nil];
    if (carrierPath.count > 1) [stages addObjectsFromArray:[carrierPath subarrayWithRange:NSMakeRange(1, carrierPath.count - 1)]];

    return stages;
}


- (void)startStallWatchers {
#if VIBE_VERBOSE_LOGGING
    // The main thread is one per process, so its watcher is too; its port is
    // read on the main thread itself, where the production player is made,
    // since there is no public way to name the main thread from another.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#if TARGET_OS_OSX
        VibeWatchMainThreadForStalls(NSThread.isMainThread ? pthread_mach_thread_np(pthread_self()) : MACH_PORT_NULL);
#else
        VibeWatchMainThreadForStalls(MACH_PORT_NULL);
#endif
    });
    // The player queue runs on whichever pool thread is free; the watcher
    // finds the one draining it at each sample.
    _queueStallWatcher = VibeWatchQueueForStalls(_queue, @"player queue");
#endif
}

// The queue watcher ticks while the player has work that can stall — the
// output running, or a device phase in flight on a stopped output (a bind, a
// format write, the idle stop's hog release) — and is suspended otherwise,
// so an idle player wakes nothing. Balanced: one resume per suspend.
- (void)refreshQueueStallWatcherOnQueue {
#if VIBE_VERBOSE_LOGGING
    BOOL wanted = [self renderingOnQueue] || _diagnosticPhaseDepth > 0;
    if (!_queueStallWatcher || wanted == _queueStallWatcherRunning) {
        return;
    }
    _queueStallWatcherRunning = wanted;
    if (wanted) {
        dispatch_resume(_queueStallWatcher);
    }
    else {
        dispatch_suspend(_queueStallWatcher);
    }
#endif
}

- (void)noteOutputEdgeOnQueue {
#if VIBE_VERBOSE_LOGGING
    if (![self renderingOnQueue]) {
        // No drain follows a stop to close a stall the last one opened.
        if (_renderClockStalledSince) {
            LogWarn(@"Stall: output render clock stalled %.0f ms, then the output stopped (play %llu, %@)",
                    (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - _renderClockStalledSince) / 1e6,
                    [self diagnosticPlayIdentifierOnQueue], self.currentTrack.url.lastPathComponent);
        }
        _renderClockStalledSince = 0;
        _renderClockAdvancedAt = 0;
    }
    [self refreshQueueStallWatcherOnQueue];
#endif
}

- (uint64_t)diagnosticPlayIdentifierOnQueue {
    return _state == VibePlayerStateLoading ? self.loadingSubmittedPlayIdentifier : _activeSubmittedPlayIdentifier;
}

- (BOOL)performDiagnosticPhase:(NSString *)phase device:(NSInteger)deviceID operation:(BOOL (^)(void))operation {
#if VIBE_VERBOSE_LOGGING
    uint64_t play = [self diagnosticPlayIdentifierOnQueue];
    uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    LogInfo(@"Phase: play %llu voice %llu %@ begin, target %ld, state %ld", play, _voice, phase, (long)deviceID, (long)_state);
    _diagnosticPhaseDepth++; // HAL work on a stopped output: the queue watcher runs for it
    [self refreshQueueStallWatcherOnQueue];
#endif
    BOOL success = operation();
#if VIBE_VERBOSE_LOGGING
    _diagnosticPhaseDepth--;
    [self refreshQueueStallWatcherOnQueue];
    LogInfo(@"Phase: play %llu voice %llu %@ end, target %ld, success %d, %.1f ms",
            play, _voice, phase, (long)deviceID, success, VibeMillisecondsSince(began));
#endif
    return success;
}

#pragma mark - Timeline

- (uint64_t)noteSubmittedPlay:(uint64_t)submittedPlay track:(AudioTrack *)track position:(NSTimeInterval)position paused:(BOOL)paused {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu submitted %@ at %.3fs, paused %d", submittedPlay, track.url.lastPathComponent, position, paused);
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    return 0;
#endif
}

- (uint64_t)noteSubmittedAction:(NSString *)action position:(NSTimeInterval)position {
#if VIBE_VERBOSE_LOGGING
    uint64_t submittedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    LogInfo(@"Timeline: %@ submitted at %llu%@", action, submittedAt,
            position >= 0 ? [NSString stringWithFormat:@" to %.3fs", position] : @"");
    return submittedAt;
#else
    return 0;
#endif
}

- (void)noteAdmittedPlay:(uint64_t)submittedPlay submittedAt:(uint64_t)submittedAt {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu admitted after %.1f ms on player queue", submittedPlay, VibeMillisecondsSince(submittedAt));
#endif
}

- (void)noteAdmittedAction:(NSString *)action submittedAt:(uint64_t)submittedAt position:(NSTimeInterval)position {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu voice %llu %@ %llu admitted after %.1f ms%@, state %ld",
            [self diagnosticPlayIdentifierOnQueue], _voice, action, submittedAt, VibeMillisecondsSince(submittedAt),
            position >= 0 ? [NSString stringWithFormat:@", target %.3fs", position] : @"", (long)_state);
#endif
}

- (void)noteOpenSettledForPlay:(uint64_t)submittedPlay track:(AudioTrack *)track file:(AudioFileHandle *)file error:(NSError *)error {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu open settled for %@, %.0f Hz, %lld frames, error %@",
            submittedPlay, track.url.lastPathComponent, file.processingFormat.sampleRate, file.length, error);
#endif
}

- (void)noteVoiceStarted:(VibeVoiceID)voice file:(AudioFileHandle *)file fromFrame:(AVAudioFramePosition)frame reason:(NSString *)reason {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu voice %llu %@ %@ from %lld of %lld frames at %.0f Hz",
            [self diagnosticPlayIdentifierOnQueue], voice, reason, file.url.lastPathComponent, frame, file.length,
            file.processingFormat.sampleRate);
    _firstRenderVoice = voice;
#endif
}

// The output's own render clock, read at every drain: the drain is the check's
// clock, so it costs no wakeup of its own and an idle player has none. A clock
// that stops means the device's IO stopped pulling audio — the one source of
// a frozen time counter that is neither the main thread nor a late first
// frame. Reports onset and recovery; noteOutputEdgeOnQueue closes a stall a
// stop cuts short. Under the pump there is no device clock to watch.
- (void)noteRenderClockOnQueue {
#if VIBE_VERBOSE_LOGGING
    if (![self drivesOutputDeviceOnQueue]) {
        return;
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL playing = _state == VibePlayerStatePlaying;
#if TARGET_OS_OSX
    // The other stall: the device keeps pulling, the pipeline cannot render.
    // A count below the last one was cleared by a measurement, not a stall.
    uint64_t dropouts = _outputUnit.dropouts;
    if (playing && dropouts > _renderClockDropouts) {
        LogWarn(@"Stall: output unit wrote silence for %llu IO cycles the pipeline could not render (play %llu, %@)",
                dropouts - _renderClockDropouts, [self diagnosticPlayIdentifierOnQueue],
                self.currentTrack.url.lastPathComponent);
    }
    _renderClockDropouts = dropouts;
#endif
    uint64_t frames = [self renderedFramesOnQueue];
    if (!playing || frames != _renderClockFrames) {
        if (_renderClockStalledSince) {
            LogWarn(@"Stall: output render clock resumed/stopped after %.0f ms (play %llu, %@)",
                    (now - _renderClockStalledSince) / 1e6, [self diagnosticPlayIdentifierOnQueue],
                    self.currentTrack.url.lastPathComponent);
        }
        _renderClockFrames = frames;
        _renderClockAdvancedAt = playing ? now : 0;
        _renderClockStalledSince = 0;
        return;
    }
    if (!_renderClockAdvancedAt) {
        _renderClockAdvancedAt = now;
    }
    if (!_renderClockStalledSince && now - _renderClockAdvancedAt > 200 * NSEC_PER_MSEC) {
        _renderClockStalledSince = _renderClockAdvancedAt;
        LogWarn(@"Stall: output render clock stalled %.0f ms (play %llu, %@)", (now - _renderClockStalledSince) / 1e6,
                [self diagnosticPlayIdentifierOnQueue], self.currentTrack.url.lastPathComponent);
#if TARGET_OS_OSX
        // Stuck in our render, or waiting for a device that stopped asking:
        // the IO thread's stack tells the two apart.
        thread_t io = VibeFindThread(nil, "com.apple.audio.IOThread.client");
        if (io == MACH_PORT_NULL) {
            LogWarn(@"Stall stack: no audio IO thread exists");
        }
        else {
            VibeSampleStack(io, @"audio IO thread", (now - _renderClockStalledSince) / 1e6, nil);
            mach_port_deallocate(mach_task_self(), io);
        }
#endif
    }
#endif
}

// The voice's own stamp names when its first frame rendered, and the live
// event precedes that render as often as not — the decoder's first fill hops
// to the drain before the audio thread has consumed — so the line waits for
// the drain that first sees the stamp. Neither proves when a DAC produced
// sound.
- (void)noteDrainOnQueue {
#if VIBE_VERBOSE_LOGGING
    [self noteRenderClockOnQueue];
    VibeVoiceID voice = _firstRenderVoice;
    if (!voice || voice != _voice) {
        return;
    }
    AudioTimeStamp start = [_voiceBus snapshotOfVoice:voice].startOfConsumption;
    if (!(start.mFlags & (kAudioTimeStampHostTimeValid | kAudioTimeStampSampleTimeValid))) {
        return; // not yet rendered
    }
    _firstRenderVoice = 0;
    NSString *when = (start.mFlags & kAudioTimeStampHostTimeValid)
            ? [NSString stringWithFormat:@"host time %llu (%.1f ms ago)", start.mHostTime,
               ([AVAudioTime secondsForHostTime:mach_absolute_time()] - [AVAudioTime secondsForHostTime:start.mHostTime]) * 1000]
            : [NSString stringWithFormat:@"sample time %.0f", start.mSampleTime];
#if TARGET_OS_OSX
    NSTimeInterval latency = _outputUnit.presentationLatency;
#else
    NSTimeInterval latency = _engine.outputNode.presentationLatency;
#endif
    LogInfo(@"Timeline: play %llu voice %llu %@ live; first render at %@; reported output presentation latency %.1f ms (not measured audible output)",
            [self diagnosticPlayIdentifierOnQueue], voice, self.currentTrack.url.lastPathComponent, when, latency * 1000);
#endif
}

- (void)noteBusEvent:(VibeVoiceEvent)event voice:(VibeVoiceID)voice current:(BOOL)current {
#if VIBE_VERBOSE_LOGGING
    NSString *name = event == VibeVoiceEventLive ? @"live" : event == VibeVoiceEventBoundary ? @"boundary" : @"ended";
    VibeVoiceSnapshot snapshot = [_voiceBus snapshotOfVoice:voice];
    LogInfo(@"Callback: play %llu voice %llu %@, %@, consumed %llu, underrun %llu frames, state %ld",
            [self diagnosticPlayIdentifierOnQueue], voice, name, current ? @"current" : @"retiring",
            snapshot.consumed, snapshot.underrunFrames, (long)_state);
    if (event == VibeVoiceEventLive && voice == _firstRenderVoice && current) {
        [self noteDrainOnQueue];
    }
    if (snapshot.underrunFrames && event == VibeVoiceEventEnded) {
        LogWarn(@"Stall: voice %llu underran %llu frames over its life", voice, snapshot.underrunFrames);
    }
#endif
}

- (void)noteSettled:(NSString *)what reason:(NSString *)reason {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu voice %llu %@ settled: %@", [self diagnosticPlayIdentifierOnQueue], _voice, what, reason);
#endif
}

- (uint64_t)deliveryStamp {
#if VIBE_VERBOSE_LOGGING
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    return 0;
#endif
}

- (void)noteDelivery:(NSString *)what forPlay:(uint64_t)submittedPlay accepted:(BOOL)accepted deliveredAt:(uint64_t)deliveredAt {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu %@ main delivery %.1f ms, %@", submittedPlay, what, VibeMillisecondsSince(deliveredAt),
            accepted ? @"accepted" : @"dropped: newer play");
#endif
}

#pragma mark - The signal probe

- (BOOL)signalProbeWanted {
    return _signalProbeWanted;
}

#if VIBE_VERBOSE_LOGGING
// Drops the probe's hold on the meter once the newest capture has completed; the
// indicator's own demand, if any, keeps the meter installed.
- (void)releaseSignalProbeOnQueue:(uint64_t)request {
    if (request != _signalProbeRequest || !_signalProbeWanted) {
        return;
    }
    _signalProbeWanted = NO;
    [self applyLevelMeterOnQueue];
}

- (void)pollOutputSignalDiagnosticsOnQueue:(AudioLevelMeter *)meter request:(uint64_t)request {
    [self scheduleAfterSeconds:0.1 block:^{
        if ([meter pollSignalDiagnostics:request]) {
            [self pollOutputSignalDiagnosticsOnQueue:meter request:request];
        }
    }];
}
#endif

- (void)armSignalProbeOnQueue:(NSString *)reason {
#if VIBE_VERBOSE_LOGGING
    // The playlist's indicator may be hidden (its column is a theme choice),
    // and a meter installed after the start misses its opening: on hardware the
    // probe holds the meter itself for each capture.
    if ([self drivesOutputDeviceOnQueue] && !_signalProbeWanted) {
        _signalProbeWanted = YES;
        [self applyLevelMeterOnQueue];
    }
    AudioLevelMeter *meter = _levelMeter;
    uint64_t play = [self diagnosticPlayIdentifierOnQueue], voice = _voice;
    NSString *track = self.currentTrack.url.lastPathComponent;
    __block uint64_t request = 0;
    __weak AudioPlayer *weakSelf = self;
    request = [meter beginSignalDiagnosticsAtTime:[self outputRenderTimeOnQueue]
                         waitingForRetiredAudio:_retiringVoices.count > 0
                                     completion:^(NSDictionary *snapshot) {
        if (!([snapshot[@"completion"] isEqual:@"superseded"] && [snapshot[@"status"] isEqual:@"no buffers observed"])) {
            LogInfo(@"Signal: play %llu voice %llu %@ %@ capture %@", play, voice, track, reason, snapshot);
        }
        // Not from inside the meter's own call: releasing the demand may remove it.
        AudioPlayer *player = weakSelf;
        if (player) dispatch_async(player->_queue, ^{ [player releaseSignalProbeOnQueue:request]; });
    }];
    if (!request) {
        LogInfo(@"Signal: play %llu voice %llu %@ %@ unavailable: no active level meter (post-mix observation, not audible output)",
                play, voice, track, reason);
    }
    if (request) [self pollOutputSignalDiagnosticsOnQueue:meter request:request];
    _signalProbeRequest = request;
    if (!request) [self releaseSignalProbeOnQueue:0];
#endif
}

// TRAP: the varispeed emits the bus's frames its declared latency late —
// about 1 ms (measured) — so the last frames of a faded voice reach the
// meter that long after the render saw the voice die, and the cutoff pads
// for it whenever the varispeed is in the chain, which is while the pitch is
// off zero (varispeedLatencyOnQueue reads 0 otherwise: at zero the render
// skips the unit); without the pad the probe reads the outgoing track's tail
// as the incoming one's first signal. The FX chain adds nothing: an idle
// chain is skipped, and the meter reads the render's final samples.
- (void)noteRetiringAudioSilentOnQueue {
#if VIBE_VERBOSE_LOGGING
    AVAudioTime *time = [self outputRenderTimeOnQueue];
    NSTimeInterval latency = [self varispeedLatencyOnQueue];
    if (time && latency > 0) {
        AudioTimeStamp stamp = time.audioTimeStamp;
        if (time.sampleTimeValid) stamp.mSampleTime += ceil(latency * time.sampleRate);
        if (time.hostTimeValid) stamp.mHostTime += [AVAudioTime hostTimeForSeconds:latency];
        time = [AVAudioTime timeWithAudioTimeStamp:&stamp sampleRate:time.sampleRate];
    }
    [_levelMeter endSignalOverlapAtTime:time];
#endif
}

#pragma mark - The first displayed position

- (void)notePublishedPlayingPosition:(NSTimeInterval)position track:(AudioTrack *)track voice:(VibeVoiceID)voice {
#if VIBE_VERBOSE_LOGGING
    NSDictionary *diagnostic = track ? @{
        @"track": track, @"play": @([self diagnosticPlayIdentifierOnQueue]), @"voice": @(voice),
        @"position": @(position), @"publishedAt": @(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) } : nil;
    os_unfair_lock_lock(&_stateLock);
    _positionDiagnostic = diagnostic;
    os_unfair_lock_unlock(&_stateLock);
#endif
}

- (void)recordDisplayedPosition:(NSTimeInterval)position forTrack:(AudioTrack *)track {
#if VIBE_VERBOSE_LOGGING
    os_unfair_lock_lock(&_stateLock);
    NSDictionary *diagnostic = _positionDiagnostic;
    BOOL matches = track && diagnostic[@"track"] == track
            && [diagnostic[@"play"] unsignedLongLongValue] == _nextSubmittedPlayIdentifier
            && position > [diagnostic[@"position"] doubleValue];
    if (matches) _positionDiagnostic = nil;
    os_unfair_lock_unlock(&_stateLock);
    if (matches) {
        LogInfo(@"Timeline: play %@ voice %@ first advancing UI position %.3fs (published %.3fs), %.1f ms after state publication",
                diagnostic[@"play"], diagnostic[@"voice"], position, [diagnostic[@"position"] doubleValue],
                VibeMillisecondsSince([diagnostic[@"publishedAt"] unsignedLongLongValue]));
    }
#endif
}

@end
