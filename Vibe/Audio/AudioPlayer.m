//
//  AudioPlayer.m
//  Vibe
//

#import "AudioPlayer.h"
#import "AudioPlayerInternal.h"
#if DEBUG
#import "VibeManualRenderPump.h"
#import "AudioPlayer+Debug.h"
#endif
#import "AudioFX.h"
#import "AudioLoadingConfiguration.h"
#import "AudioTrack.h"
// The HAL device layer is macOS-only; iOS routing is AVAudioSession's, handled
// in the app layer (Audio/iOS/AudioSessionController).
#if TARGET_OS_OSX
#import "AudioPlayer+Devices.h"
#import "AudioDeviceManager.h"
#import "CoreAudioUtil.h"
#endif
#import "AudioFileOpenTimeoutMath.h"
#import "PlaybackDeliveryRules.h"
#import "FadeMath.h"
#import "GaplessSpliceMath.h"
#import "PlaybackRequestCoordinator.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

#if DEBUG
@interface AudioLevelPublisher (AudioPlayerDebugPrivate)
- (NSDictionary<NSString *, NSNumber *> *)debugState;
@end
#endif

// Descriptions are NOT localized: every consumer is a log site. The UI status
// comes from VibeStatusForPlayError (AudioErrorRules.h), which maps the error
// code and localizes there, once for both platforms.
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError *underlying) {
    NSMutableDictionary *info = [NSMutableDictionary new];
    if (underlying) {
        info[NSUnderlyingErrorKey] = underlying;
        if (underlying.localizedDescription.length) {
            description = [NSString stringWithFormat:@"%@ (%@)", description, underlying.localizedDescription];
        }
    }
    info[NSLocalizedDescriptionKey] = description;
    return [NSError errorWithDomain:kVibeAudioErrorDomain code:code userInfo:info];
}

// Play-path variant: stamps the failing track's URL so the delegate can drop
// a delivery a track change has outrun (see kVibeAudioErrorTrackURLKey).
NSError *VibeAudioErrorForTrack(VibeAudioErrorCode code, NSString *description, NSError *underlying, NSURL *trackURL) {
    NSError *error = VibeAudioError(code, description, underlying);
    if (!trackURL) {
        return error;
    }
    NSMutableDictionary *info = [error.userInfo mutableCopy];
    info[kVibeAudioErrorTrackURLKey] = trackURL;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:info];
}

// How long a file open may block before the play request is abandoned is
// AudioFileOpenTimeoutMath.h's monotonic deadline: a 60s no-progress baseline
// and 60s of silence after positive movement, configurable for diagnostics.

// An open still pending after this long is worth a visible loading state.
static const NSTimeInterval kSlowOpenIndicatorDelaySeconds = 0.5;

// An open taking this long is worth recording. Separate from the indicator
// delay above, which is a UI choice: a start the user feels is slow can be
// well under the threshold at which showing a spinner is worthwhile.
static const NSTimeInterval kSlowOpenLogThresholdSeconds = 0.25;

#if TARGET_OS_IOS
// Keeps iOS recovery's last-rendered playhead current when the screen's UI
// timer is dormant. This reads render time without mutating the engine.
static const NSTimeInterval kRecoveryPositionSampleIntervalSeconds = 0.5;
#endif

// Default pitch fader range in percent: ±8%, matching a stock SL-1200.
static const float kDefaultMaxPitchPercent = 8.0f;

// Queue-specific key marking _queue, so synchronous helpers can tell whether
// they already run on this exact player's queue. A process can briefly own two
// players during lifecycle tests or replacement.
static void *const kAudioPlayerQueueKey = (void *)&kAudioPlayerQueueKey;

@interface AudioPlayer ()
- (instancetype)initWithDeviceUID:(NSString *)uid modelUID:(NSString *)modelUID name:(NSString *)name enableFX:(BOOL)enableFX delegate:(id<AudioPlayerDelegate>)delegate loadingConfiguration:(AudioLoadingConfiguration *)configuration manualPump:(id)pump;
// playOnQueue:'s phases; the ordering constraints between them are commented
// there, at the call sites.
- (BOOL)rebindLoadingPlayOnQueueForTrack:(AudioTrack *)track
                                    path:(NSString *)path
                                  intent:(VibePendingPlaybackIntent)intent
                 submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier;
- (void)retireOutgoingChainOnQueueWithDeclick:(BOOL)declick;
- (void)supersedePreviousOpenOnQueueForPath:(NSString *)path;
- (BOOL)consumePrefetchedFileOnQueueForPath:(NSString *)path
                              openRequestId:(uint64_t)openId;
- (void)submitOpenOnQueueForTrack:(AudioTrack *)track
                    openRequestId:(uint64_t)openId;
- (void)cancelPlayOpenOnQueue;
- (void)cancelPlayOpenForRequest:(uint64_t)openId;
- (void)pauseOnQueue;
- (void)resumeOnQueue;
- (void)cancelPendingPauseOnQueue;
#if TARGET_OS_IOS
- (void)scheduleRecoveryPositionSampleForGeneration:(uint64_t)generation;
#endif
@end

// The state a category also touches is in AudioPlayerInternal.h; what follows
// is private to this file.
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
// symbolicate against the archived dSYM for the build the report names. A run
// of one frame collapses to one entry: a recursive layout pass repeats its
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

// Beta instrumentation (#47): a queue that takes more than 200 ms to run an
// empty block was blocked by something, and the log says for how long, so a
// reported freeze can be told apart from late audio. For the main thread the
// watcher also captures, once per stall, where it is stuck, 250 ms in. The
// timers live as long as the process.
static void VibeWatchQueueForStalls(dispatch_queue_t queue, NSString *name, mach_port_t sampledThread) {
    static NSMutableArray *timers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ timers = [NSMutableArray array]; });
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
            // 250 ms in, then every 500 ms: a long freeze can move between
            // causes, and a single sample would show only the first.
            if (stuck > 250 * NSEC_PER_MSEC && stuck >= nextSampleAt && samples < 6) {
                if (!samples) {
                    LogWarn(@"Stall: the %@ is still blocked after %.0f ms", name, stuck / 1e6);
                }
                samples++;
                nextSampleAt = stuck + 500 * NSEC_PER_MSEC;
#if TARGET_OS_OSX
                // The player queue has no fixed thread: find whichever pool
                // thread is draining it. None means it is queued but starved.
                thread_t thread = sampledThread != MACH_PORT_NULL ? sampledThread : VibeFindThread(queue, NULL);
                if (thread == MACH_PORT_NULL) {
                    LogWarn(@"Stall stack: the %@, %.0f ms in: no thread is running it", name, stuck / 1e6);
                }
                else {
                    lastStack = VibeSampleStack(thread, name, stuck / 1e6, lastStack);
                    if (thread != sampledThread) {
                        mach_port_deallocate(mach_task_self(), thread);
                    }
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
    dispatch_resume(timer);
    @synchronized (timers) {
        [timers addObject:timer];
    }
}

static void VibeWatchOutputRender(AudioPlayer *player);
#endif

@implementation AudioPlayer {
#if VIBE_VERBOSE_LOGGING
    NSDictionary *_positionDiagnostic; // _stateLock; consumed once by main
#endif
    float                   _maxPitch;
    // The fade-in length for the play in flight: the user-set crossfade when
    // it replaced an audibly playing track, the declick minimum otherwise.
    // Written by playOnQueue: alongside the matching retire, read by
    // finishPlayOnQueueWithFile:error:openRequestId:'s fade-in. Queue-confined.
    uint64_t                _incomingFadeMilliseconds;
    AudioLoadingConfiguration *_loadingConfiguration;
    id                      _configChangeObserver;
#if DEBUG
    // --no-audio-hw's stand-in for the HAL IO thread; see
    // VibeManualRenderPump. Non-nil exactly while manual rendering is active,
    // which is what manualRenderingActive answers from.
    VibeManualRenderPump    *_manualPump;
#endif
}

#pragma mark - Init

- (instancetype)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName
                         enableFX:(BOOL)enableFX delegate:(id <AudioPlayerDelegate>)delegate {
    return [self initWithDeviceUID:deviceUID
                              name:deviceName
                          enableFX:enableFX
                          delegate:delegate
              loadingConfiguration:[AudioLoadingConfiguration productionConfiguration]];
}

- (instancetype)initWithDeviceUID:(NSString *)deviceUID modelUID:(NSString *)modelUID
                             name:(NSString *)deviceName enableFX:(BOOL)enableFX
                         delegate:(id <AudioPlayerDelegate>)delegate {
    return [self initWithDeviceUID:deviceUID modelUID:modelUID name:deviceName enableFX:enableFX
                          delegate:delegate
              loadingConfiguration:[AudioLoadingConfiguration productionConfiguration] manualPump:nil];
}

- (instancetype)initWithDeviceUID:(NSString *)deviceUID
                              name:(NSString *)deviceName
                          enableFX:(BOOL)enableFX
                          delegate:(id<AudioPlayerDelegate>)delegate
              loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    return [self initWithDeviceUID:deviceUID modelUID:@"" name:deviceName enableFX:enableFX delegate:delegate
             loadingConfiguration:loadingConfiguration manualPump:nil];
}

- (instancetype)initWithDeviceUID:(NSString *)deviceUID modelUID:(NSString *)modelUID
                             name:(NSString *)deviceName
                         enableFX:(BOOL)enableFX delegate:(id<AudioPlayerDelegate>)delegate
             loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration manualPump:(id)pump {
    NSParameterAssert(loadingConfiguration);
    self = [super init];
    if (self) {
        _stateLock = OS_UNFAIR_LOCK_INIT;
        _state = VibePlayerStateStopped;
        _pendingSeekPosition = -1;
        _pendingRequest = [PlaybackRequestCoordinator new];
        _maxPitch = kDefaultMaxPitchPercent;
        _crossfadeMilliseconds = kFadeDurationMilliseconds;
        _loadingConfiguration = [loadingConfiguration copy];
        // Meaningful before the async init block resolves the saved device:
        // -1 means follow the system default, rather than a bogus device id 0.
        self.currentlyRequestedAudioDeviceId = -1;
        // Default QoS, not user-initiated. This queue owns the engine graph
        // and calls blocking AVAudioEngine APIs — [node stop], detachNode:,
        // engine start and stop — which wait on the engine's internal
        // graph-reconfiguration thread, itself at Default QoS. A
        // user-initiated queue blocking on that lower-QoS thread is a priority
        // inversion, which the Thread Performance Checker flagged on the skip
        // teardown. Matching Default removes it. The latency-critical file
        // open runs on the coordinator's bounded user-initiated lane (see
        // playOnQueue:), so leaving control-plane scheduling at Default costs
        // nothing perceptible.
        _queue = dispatch_queue_create("com.vibe.audioplayer",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, 0));
        dispatch_queue_set_specific(_queue, kAudioPlayerQueueKey,
                                    (__bridge void *)self, NULL);
#if VIBE_VERBOSE_LOGGING
        // The production player only: the render suites drive their own clock
        // and hold the queue on purpose.
        if (!pump) {
#if TARGET_OS_OSX
            // Read on the main thread itself, where the production player is
            // made; there is no public way to name the main thread from another.
            VibeWatchQueueForStalls(dispatch_get_main_queue(), @"main thread",
                                    NSThread.isMainThread ? pthread_mach_thread_np(pthread_self()) : MACH_PORT_NULL);
#else
            VibeWatchQueueForStalls(dispatch_get_main_queue(), @"main thread", MACH_PORT_NULL);
#endif
            // The player queue runs on whichever pool thread is free; the
            // watcher finds the one draining it at each sample.
            VibeWatchQueueForStalls(_queue, @"player queue", MACH_PORT_NULL);
            VibeWatchOutputRender(self);
        }
#endif
        // Keep the macOS controls and BPM feed stable across live toggles;
        // the FX nodes themselves are created only when first connected.
        _fxEnabled = enableFX;
        __weak AudioPlayer *weakPlayer = self;
        _fx = (enableFX || TARGET_OS_OSX) ? [[AudioFX alloc] initWithQueue:_queue scheduler:^(NSTimeInterval seconds, dispatch_block_t block) {
            [weakPlayer scheduleAfterSeconds:seconds block:block];
        }] : nil;
#if DEBUG
        _manualPump = pump;
#endif
        _retiredFades = [NSMutableArray array];
        _prefetchRequestState = VibeAudioPrefetchRequestStateMake();
        _levelNormalizationMode = kLevelDefaultNormalizationMode;
        _levelPublisher = [[AudioLevelPublisher alloc] init];
#if TARGET_OS_OSX
        _pendingSavedDeviceUID = [deviceUID copy] ?: @"";
        _pendingSavedDeviceModelUID = [modelUID copy] ?: @"";
        _pendingSavedDeviceName = [deviceName copy] ?: @"";
#endif
        self.delegate = delegate;
        dispatch_async(_queue, ^{

            LogDebug(@"AudioPlayer init");

            [self createEngineAndMasterBusOnQueue];

#if TARGET_OS_OSX
            if (!self->_engine.isInManualRenderingMode) {
                AudioDeviceManager *deviceManager = [AudioDeviceManager sharedInstance];
                [deviceManager addObserver:self];

                __weak AudioPlayer *weakSelf = self;
                self->_configChangeObserver = [[NSNotificationCenter defaultCenter]
                        addObserverForName:AVAudioEngineConfigurationChangeNotification
                                    object:self->_engine
                                     queue:nil
                                usingBlock:^(NSNotification *note) {
                                    AudioPlayer *strongSelf = weakSelf;
                                    if (strongSelf) {
#if VIBE_VERBOSE_LOGGING
                                        LogInfo(@"Callback: AVAudioEngine configuration changed (engine %@)",
                                                strongSelf->_engine.isRunning ? @"running" : @"stopped");
#endif
                                        dispatch_async(strongSelf->_queue, ^{
                                            [strongSelf handleEngineConfigurationChange];
                                        });
                                    }
                                }];
                // Do not put first-use HAL discovery on the player's sole queue.
                // The engine begins honestly on System Output; a successful async
                // snapshot later applies the saved preference through the checked
                // device-switch path, and an absent device remains pending.
                [self resolvePendingSavedOutputDeviceOnQueue];
            }
#endif
            // On iOS there is no HAL device layer: routing belongs to
            // AVAudioSession, and engine-config-change handling lives with the
            // session observer in the iOS app layer.

            run_on_main_thread({
                [self.delegate audioPlayerDidInitialize:self];
            });

        });
    }
    return self;
}

// The one home for the same-queue guard every synchronous accessor needs:
// the queue key is set on _queue at init, so a caller already there runs the
// block inline rather than deadlocking on itself.
- (BOOL)leavesSamplesUntouchedOnQueue {
#if TARGET_OS_OSX
    return _bitPerfectWanted;
#else
    return NO;
#endif
}

- (void)runSyncOnQueue:(NS_NOESCAPE dispatch_block_t)block {
    if (dispatch_get_specific(kAudioPlayerQueueKey) == (__bridge void *)self) {
        block();
        return;
    }
    dispatch_sync(_queue, block);
}

- (void)scheduleAfterSeconds:(NSTimeInterval)seconds block:(dispatch_block_t)block {
#if DEBUG
    if (_manualPump) { [_manualPump scheduleAfter:seconds block:block]; return; }
#endif
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), _queue, block);
}

- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    NSParameterAssert(loadingConfiguration);
    [self runSyncOnQueue:^{
        self->_loadingConfiguration = [loadingConfiguration copy];
    }];
}

// Runs on _queue. Creates the engine and wires the master bus, applying the
// debug argv flags exactly as first init does. The iOS media-services rebuild
// calls this too, so a rebuilt engine comes back in the same mode — without
// that, --no-audio-hw's pump would render against a non-manual engine, and a
// --silent run would turn audible after a reset.
- (void)createEngineAndMasterBusOnQueue {
    _engine = [[AVAudioEngine alloc] init];

#if DEBUG
    // --no-audio-hw, for testing: put the engine in manual rendering mode so
    // it never opens a CoreAudio output device. Starting the hardware IO —
    // even with the mixer muted — counts as the Mac playing audio, which is
    // enough for macOS to yank auto-switching AirPods over from another device
    // mid-test. In manual mode the graph, scheduling, fades, FX, completions
    // and position all behave normally; the pump below pulls frames at
    // real-time pace and discards them. Must be enabled while the engine is
    // stopped and before the graph is wired.
    BOOL noAudioHW = _manualPump != nil || [NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"];
    BOOL manualRendering = NO;
    if (noAudioHW) {
        NSError *manualError = nil;
        AVAudioFormat *renderFormat = _manualPump.format ?: [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0 channels:2];
        manualRendering = [_engine
                enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                   format:renderFormat
                        maximumFrameCount:kVibeManualPumpMaxFrames
                                    error:&manualError];
        if (!manualRendering) {
            if (_manualPump) [NSException raise:NSInternalInconsistencyException format:@"Manual rendering required: %@", manualError];
            // The engine will open the output device as it always does; pair
            // --no-audio-hw with --silent, as launch.sh does, and playback at
            // least stays inaudible.
            LogError(@"AudioPlayer: --no-audio-hw manual rendering unavailable (%@)", manualError);
        }
    }
#endif

#if DEBUG
    if (manualRendering) {
        [_engine connect:_engine.mainMixerNode to:_engine.outputNode format:_engine.manualRenderingFormat];
        // Rebuilds keep the same clock; attach cancels the old timer.
        if (!_manualPump) _manualPump = [[VibeManualRenderPump alloc] initWithFormat:_engine.manualRenderingFormat automatic:YES];
        [_manualPump attachToEngine:_engine queue:_queue];
        LogInfo(@"AudioPlayer: --no-audio-hw, manual rendering, no output device");
    }
#endif
    [self installMasterBusOnQueue];
#if DEBUG
    // --silent, for testing: zero the main mixer so that playback runs
    // normally but nothing audible reaches the output device, which still gets
    // opened and driven — use --no-audio-hw to keep hardware untouched. It
    // sits downstream of all fade ramps, which are player-node volumes, and
    // upstream of the FX returns, so wet tails are silenced too. It must run
    // after the master bus is wired, because a mixer volume written before the
    // mixer is attached and wired is silently dropped. See AudioFX.m.
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--silent"]) {
        _engine.mainMixerNode.outputVolume = 0;
        LogInfo(@"AudioPlayer: --silent, output muted");
    }
#endif
}

// Wires the master bus — everything from the main mixer to the output: the FX
// segment when FX is enabled and bit-perfect is off, otherwise a direct
// mixer -> output connection. The explicit connect stands in for the implicit
// one AVAudioEngine makes on mainMixerNode access, so the wiring is the same
// deterministic step in every configuration. Runs on _queue with the engine
// stopped: the engine init, the iOS media-services-reset rebuild, and the
// macOS device rebind whenever the standing route disagrees with the flags.
- (void)installMasterBusOnQueue {
    // Apple's default SRC leaves measurable ultrasonic aliases when reducing
    // the output rate. The render suite holds their RMS below -90 dBFS.
    _engine.mainMixerNode.AUAudioUnit.renderQuality = kRenderQuality_Max;
    [self reconnectMasterBusOnQueueWithFormat:[_engine.mainMixerNode outputFormatForBus:0]];
}

// Engine stopped. Initialization, mode changes and device rates share this wiring.
- (void)reconnectMasterBusOnQueueWithFormat:(AVAudioFormat *)format {
    [_levelTap remove];
    _levelTap = nil;
    BOOL enableFX = _fxEnabled;
#if TARGET_OS_OSX
    enableFX &= !_bitPerfectWanted;
#endif
    [_fx setConnected:enableFX inEngine:_engine format:format];
    if (!_fx.masterBusOutputNode) {
        [_engine connect:_engine.mainMixerNode to:_engine.outputNode format:format];
    }
    // TRAP: every master-bus rewire must reconcile the tap on the new output path.
    [self applyLevelTapOnQueue];
}

// Runs on _queue. Reconciles the tap with the queue-side intent, which is the
// only thing either caller has to get right.
- (void)applyLevelTapOnQueue {
    BOOL wanted = _levelsWanted || _signalProbeWanted;
    if (wanted && _engine && !_levelTap && _levelPublisher) {
        // Whatever feeds the output, which is the only place the bars can
        // follow what is actually heard: the FX segment's sum when there is
        // one, and the mixer itself when there is not. Tapping the mixer
        // unconditionally would miss every reverb and delay tail, since those
        // returns re-enter downstream of it.
        AVAudioNode *tapNode = _fx.masterBusOutputNode ?: _engine.mainMixerNode;
        _levelTap = [[AudioLevelTap alloc] initWithNode:tapNode
                                              publisher:_levelPublisher
                                       normalizationMode:_levelNormalizationMode];
        if (_node.isPlaying) [self beginOutputSignalDiagnosticsOnQueue:@"tap installed during playback"];
    }
    else if (!wanted && _levelTap) {
        [_levelTap remove];
        _levelTap = nil;
    }
}

- (void)setLevelsEnabled:(BOOL)levelsEnabled {
    if (_levelsEnabled == levelsEnabled) {
        return;
    }
    _levelsEnabled = levelsEnabled;
    // The intent crosses to the queue as a captured value rather than as a
    // read of the main-thread property from the block.
    dispatch_async(_queue, ^{
        self->_levelsWanted = levelsEnabled;
        [self applyLevelTapOnQueue];
    });
}

- (BOOL)copyBandLevels:(float *)out count:(NSUInteger)count sequence:(uint64_t *)sequence {
    return [_levelPublisher copyLevels:out count:count sequence:sequence];
}

// Runs on _queue. Forgets every reference bound to the current engine without
// messaging it — the caller may hold a defunct engine whose graph must not be
// touched, as after an iOS media-services reset (see AudioPlayer+Recovery.m).
// Emptying the retired-fade registry halts the steppers; the open, prefetch
// and gapless state goes because a parked AVAudioFile — the prefetched handle
// and the splice's private one alike — dies with the media server.
- (void)dropEngineBoundStateOnQueue {
    [_retiredFades removeAllObjects];
    _varispeed = nil;
    // Abandoned rather than removed: removeTapOnBus: would message a node
    // belonging to the engine this method exists to stop touching. The rebuild
    // installs a fresh tap from installMasterBusOnQueue.
    [_levelTap abandon];
    _levelTap = nil;
    // refreshOutputAudioActiveOnQueue begins by asking _engine.isRunning.
    // Drop the invalid engine first so that refresh and the following Stopped
    // publication message nil, never the media server's dead object.
    _engine = nil;
    _retiredOutputGeneration++;
    _activeRetiredOutputCount = 0;
    [self refreshOutputAudioActiveOnQueue];
    // Neither transfer has a consumer any more — the deliveries below are
    // invalidated by identifier, and the file handles they would produce died
    // with the media server. A download is not engine-bound state, so nothing
    // else here reaches it, and left alone it pulls a whole file down for a
    // play that can never land. Same pair stop cancels.
    [self cancelPlayOpenOnQueue];
    [self clearPrefetchOnQueue];
    // Every in-flight open dies with the media server; the coordinator's
    // identifier makes each late delivery a no-op, exactly as on the reset
    // path.
    [_pendingRequest invalidate];
    [self clearGaplessOnQueue];
}

- (void)dealloc {
    if (_configChangeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_configChangeObserver];
    }
#if DEBUG
    [_manualPump cancel];
#endif
#if TARGET_OS_OSX
    if (_outputDeviceListener) AUListenerDispose(_outputDeviceListener);
    if (_outputLevelListener) {
        [CoreAudioUtil removeOutputLevelListener:_outputLevelListener queue:_queue forDeviceID:_preparedDeviceID];
    }
    if (_configChangeObserver) [[AudioDeviceManager sharedInstance] removeObserver:self];
#endif
    // Engine mutation belongs on _queue, as everywhere else. dispatch_sync
    // from here cannot deadlock against in-flight queue work: a queued block
    // either holds a strongSelf, in which case the retain count is nonzero and
    // dealloc is not running, or resolves its weakSelf to nil and returns
    // without dispatching anywhere, and run_on_main_thread is async besides.
    // The one remaining hazard is dealloc itself running on _queue, when a
    // queued block releases the last reference, so that case tears down
    // inline.
    AudioLevelTap *levelTap = _levelTap;
    _levelTap = nil;
    AVAudioPlayerNode *node = _node;
    AVAudioEngine *engine = _engine;
    // Locals, not self: the coordinator claims and their path-wide
    // materialization requests outlive the player otherwise, pulling a whole
    // file down for a play that can never land — same waste the reset path's
    // cancelPlayOpenOnQueue/clearPrefetchOnQueue pair exists to stop.
    AudioFileOpenToken *playOpenToken = _playOpenToken;
    _playOpenToken = nil;
    AudioFileOpenToken *prefetchOpenToken = _prefetchOpenToken;
    _prefetchOpenToken = nil;
    AudioFileOpenToken *gaplessOpenToken = _gaplessOpenToken;
    _gaplessOpenToken = nil;
    PlaybackRequestCoordinator *pendingRequest = _pendingRequest;
    dispatch_block_t teardown = ^{
        [playOpenToken cancel];
        [prefetchOpenToken cancel];
        [gaplessOpenToken cancel];
        [pendingRequest invalidate];
        [levelTap remove];
        [node stop];
        [engine stop];
    };
    if (dispatch_get_specific(kAudioPlayerQueueKey) == (__bridge void *)self) {
        teardown();
    }
    else {
        dispatch_sync(_queue, teardown);
    }
}

#pragma mark - Playback

- (void)play:(AudioTrack *)track {
    [self playTrack:track atPosition:0 startPaused:NO declick:NO];
}

// Convert resumes the same audio in place; playlist removal uses this to land
// a replacement parked. Both declick rather than crossfade: the first would
// only dip identical audio, and the second should render nothing until resume.
- (void)play:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused {
    [self playTrack:track atPosition:position startPaused:startPaused declick:YES];
}

- (void)playTrack:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused declick:(BOOL)declick {
    VibePendingPlaybackIntent intent = VibePendingPlaybackIntentMake(position, startPaused);
    // TRAP: identifier minting and queue admission are one ordering edge.
    // Media-reset receipt takes the same lock around its queue admission, so
    // a play cannot be identified on one side of the reset and execute on the
    // other. The queue block may briefly wait for this lock to be released;
    // it never holds the queue while asking another thread to acquire it.
    os_unfair_lock_lock(&_stateLock);
    uint64_t submittedPlayIdentifier = ++_nextSubmittedPlayIdentifier;
    _lastSubmittedPlayIdentifier = submittedPlayIdentifier;
    _lastSubmittedPlayTrack = track;
#if VIBE_VERBOSE_LOGGING
    uint64_t requestedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    LogInfo(@"Timeline: play %llu submitted %@ at %.3fs, paused %d",
            submittedPlayIdentifier, track.url.lastPathComponent, position, startPaused);
#endif
    dispatch_async(_queue, ^{
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Timeline: play %llu admitted after %.1f ms on player queue", submittedPlayIdentifier,
                (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - requestedAt) / 1e6);
#endif
        [self playOnQueue:track intent:intent declick:declick
   submittedPlayIdentifier:submittedPlayIdentifier];
    });
    os_unfair_lock_unlock(&_stateLock);
}

// One play submission, as the ordered phases it is: retire the superseded
// successor, try to rebind an identical in-flight play, retire the outgoing
// chain, commit to Loading, supersede the previous open, then either consume a
// prefetched handle or admit a new one. The order is the correctness; each
// phase's own reasoning is at its method, and the constraints BETWEEN them are
// commented here, where the call sites are next to each other.
- (void)playOnQueue:(AudioTrack *)track
              intent:(VibePendingPlaybackIntent)intent
             declick:(BOOL)declick
submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    if (_terminating) return;
    NSString *path = track.url.path;

    // Every explicit play submission retires the successor request belonging
    // to the playback context it superseded. This precedes the rebind, which
    // returns early but is still a newer submission.
    [self terminallyRetirePrefetchRequestOnQueue];
    // A parked play is a pause outcome. Cut any older crossfade tail before the
    // same-path Loading rebind can return without touching the graph.
    if (intent.paused) {
        [self preemptRetiredFadesOnQueue];
    }
    if ([self rebindLoadingPlayOnQueueForTrack:track
                                          path:path
                                        intent:intent
                       submittedPlayIdentifier:submittedPlayIdentifier]) {
        return;
    }

    _activeSubmittedPlayIdentifier = 0;

    // Before the state flips to Loading below: the retire's crossfade decision
    // asks whether it is replacing an AUDIBLY playing track, which Loading
    // would answer NO to.
    [self retireOutgoingChainOnQueueWithDeclick:declick];

    self.currentTrack = nil;
    LogDebug(@"play file: %@", path);
    uint64_t openId = [_pendingRequest beginWithTrack:track
                                                   path:path
                                                 intent:intent
                                  submittedPlayIdentifier:submittedPlayIdentifier];

    // Enter the loading state: no node or file yet, but a play is committed.
    // This clears the previous track's file and position, so the UI stops
    // showing a stale duration and position for up to the full open timeout.
    // publishPlaybackState: has already mirrored the request, so this only has
    // to retire the pre-Loading handoff a seek would otherwise still aim at.
    [self publishPlaybackState:VibePlayerStateLoading node:nil file:nil segmentStart:0 position:0];
    [self clearSubmittedPlayIdentifier:submittedPlayIdentifier];

    [self supersedePreviousOpenOnQueueForPath:path];

    // Loading is published above either way, so the fast path lands in the
    // same state the slow one does — it just never arms an open's timers.
    if ([self consumePrefetchedFileOnQueueForPath:path openRequestId:openId]) {
        return;
    }
    [self submitOpenOnQueueForTrack:track openRequestId:openId];
}

// Attempted only inside Loading, because rebindTrack: MUTATES the request it
// matches: outside this branch the mutation would be made and then thrown away
// by playOnQueue:'s beginWithTrack:. YES means this play is fully handled.
//
// This exact file is already loading, with its open in flight. Do not start
// another open: that would strand a second blocked worker and, on a slow file,
// flash a spurious timeout error before the first one completes. Do rebind the
// delivery to the new track object, though. A re-drop replaces the playlist
// with fresh AudioTrack instances, and completing with the old one would orphan
// the open's result. Nothing here touches the graph or the open, so re-clicking
// the loading row is a true no-op rather than a generation bump plus a
// varispeed swap whose in-flight open then plays through a needlessly rebuilt
// chain.
- (BOOL)rebindLoadingPlayOnQueueForTrack:(AudioTrack *)track
                                    path:(NSString *)path
                                  intent:(VibePendingPlaybackIntent)intent
                 submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    if (_state != VibePlayerStateLoading) {
        return NO;
    }
    VibePlaybackRequestRebind rebind = [_pendingRequest rebindTrack:track
                                                               path:path
                                                             intent:intent
                                            submittedPlayIdentifier:submittedPlayIdentifier];
    if (!rebind.matched) {
        return NO;
    }
    VibePlaybackRequest *request = _pendingRequest.currentRequest;
    [self mirrorLoadingRequest:request
      clearingSubmittedPlayIdentifier:submittedPlayIdentifier];
    if (rebind.shouldNotifySlowLoad) {
        [self notifyDidBeginLoadingForRequest:request];
    }
    if (rebind.shouldNotifyLoadingPaused) {
        [self notifyLoadingPausedForRequest:request];
    }
    return YES;
}

// Retires the playing chain and stands the incoming one up beside it.
//
// Dual-varispeed crossfade: the incoming track gets a brand-new varispeed, and
// the outgoing node retires together with its old one. The outgoing node's live
// connection is therefore never rerouted. Rerouting a running node reconfigures
// the graph and clicks, which is why the seek path never reconnects either;
// here we only ramp its volume. The two tracks ride independent
// player->varispeed->mixer chains, so the incoming connect cannot steal the
// outgoing bus, and each varispeed is connected exactly once, for one track's
// format. There is no cross-format reconnection; see
// connectNode:throughVarispeedWithFormat:.
- (void)retireOutgoingChainOnQueueWithDeclick:(BOOL)declick {
    _segmentGeneration++;
    [self preemptRampsOnQueue]; // preempt any in-flight resume fade-in
    // Any armed splice dies with the node this play retires; the retiring
    // node's fading tail may graze the queued segment's first frames for the
    // declick length, which is inaudible at that volume. Remembered before the
    // clear: the graze reasoning holds only at declick length, so a queued
    // segment forces the retire below down to it (see the crossfade decision).
    BOOL segmentWasQueued = _gaplessQueued;
    [self clearGaplessOnQueue];

    AVAudioPlayerNode *oldNode = _node;
    AVAudioUnitVarispeed *oldVarispeed = _varispeed;
    // Whether this play replaces an audibly playing track — the only case the
    // user-set crossfade length applies to; retireNode re-makes the same check.
    // Everything else — a first play, a play from pause or stop — fades at the
    // declick minimum, so transport stays instant. Both sides of the crossfade
    // ride _incomingFadeMilliseconds: the retire here, the fade-in when the
    // open lands in finishPlayOnQueueWithFile:error:openRequestId:.
    // A queued splice segment forces the declick minimum even when the
    // crossfade setting was raised after it was armed: a crossfade-length
    // retire would let the queued file start sounding on the retiring node
    // mid-crossfade, doubled under the incoming track. (Raising the setting
    // normally unqueues via setCrossfadeMilliseconds:, but a play can land in
    // that hook's async window.)
    BOOL replacingAudibleTrack = (oldNode != nil && _engine.isRunning
                                  && _state == VibePlayerStatePlaying);
#if TARGET_OS_OSX
    // A device's mode lands before main applies its dependent settings.
    declick |= _bitPerfectWanted;
#endif
    _incomingFadeMilliseconds = VibeIncomingFadeMilliseconds(self.crossfadeMilliseconds,
                                                             replacingAudibleTrack,
                                                             declick,
                                                             segmentWasQueued);
    [self unpublishNodeOnQueue];   // oldNode above is the handle the retire uses

    _varispeed = nil;
    [self ensureVarispeedOnQueue];

    // The retire fades the outgoing side out while the incoming node fades in
    // concurrently on its own chain, in finishPlayOnQueueWithFile: — an
    // audible, true crossfade.
    [self retireNode:oldNode varispeed:oldVarispeed milliseconds:_incomingFadeMilliseconds];
}

// Reconcile the chain after a mode change, including one during a file open.
// Submission and device rebuilds share the same graph choice.
// Bit-perfect playback removes it: even at ratio 1.0 it changes the samples.
- (void)ensureVarispeedOnQueue {
#if TARGET_OS_OSX
    if (_bitPerfectWanted) {
        if (_varispeed) {
            [self detachNodeAfterFailedConnect:_varispeed];
            _varispeed = nil;
        }
        return;
    }
#endif
    if (!_varispeed) {
        AVAudioUnitVarispeed *varispeed = [[AVAudioUnitVarispeed alloc] init];
        [_engine attachNode:varispeed];
        _varispeed = varispeed;
    }
}

// Detach the previous play from its path claim and cancel any still-abortable
// materialization. If AVAudioFile has already blocked in the OS, the
// coordinator keeps the claim until it returns instead of losing track of it
// and multiplying workers on later requests.
//
// A park from the previous playlist neighborhood must not compete with the
// foreground provider transfer. A same-path park stays to race it.
- (void)supersedePreviousOpenOnQueueForPath:(NSString *)path {
    [self cancelPlayOpenOnQueue];
    [self retirePrefetchOnQueueAtPoint:VibeAudioPrefetchAtPlaySubmission
                              playPath:path];
}

// A prefetched handle for this exact path skips the open entirely, and the
// transition goes straight to schedule and play. Ownership passes to the normal
// finish path with a fresh open id, so it consumes that id like any completed
// open, and no timeout or loading-indicator timers ever exist. No materializer
// is minted: there is nothing left to download. YES means the play is finished.
- (BOOL)consumePrefetchedFileOnQueueForPath:(NSString *)path
                              openRequestId:(uint64_t)openId {
    if (!_prefetchedFile || ![path isEqualToString:_prefetchedPath]) {
        return NO;
    }
    AVAudioFile *prefetchedFile = _prefetchedFile;
    [self clearPrefetchOnQueue];
    [self finishPlayOnQueueWithFile:prefetchedFile error:nil openRequestId:openId];
    return YES;
}

// Open through the bounded interactive lane, and arm the two timers that bound
// it. The request id still pairs the logical open with its deadline, while the
// coordinator owns the underlying standardized-path claim until an
// uncancellable OS call really returns.
- (void)submitOpenOnQueueForTrack:(AudioTrack *)track
                    openRequestId:(uint64_t)openId {
    NSURL *openURL = track.url;
    _playOpenRequestId = openId;
    _openTimeoutSnapshot = _loadingConfiguration.openTimeouts;
    _openSubmittedUptime = NSProcessInfo.processInfo.systemUptime;
    _openLastPositiveMovementUptime = 0;
    __weak AudioPlayer *weakSelf = self;
    _playOpenToken = [[AudioFileMaterializationCoordinator sharedCoordinator]
            openURL:openURL
            purpose:VibeAudioFileOpenPurposePlayback
            completionQueue:_queue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval openSeconds) {
        // An open that outran the loading indicator's own threshold was a
        // materialization, near enough. How long the provider took is the one
        // number that explains a slow start, and nothing else records it.
        // Warn level so these persist: a user reporting a slow start retrieves
        // them afterwards with `log show`, which Info cannot do. Always logged,
        // not only when slow, so "nothing appeared" can only mean the open did
        // not happen. The AudioPlayer: prefix is shared by every timing line,
        // so one grep collects the whole picture.
        if (!file) {
            LogWarn(@"AudioPlayer: open of %@ abandoned after %.3fs (%@)",
                    openURL.lastPathComponent, openSeconds, error.localizedDescription);
        }
        else {
            BOOL slowOpen = openSeconds >= kSlowOpenLogThresholdSeconds;
            LogTiming(slowOpen, @"AudioPlayer: %@opened %@ in %.3fs",
                    slowOpen ? @"slowly " : @"", openURL.lastPathComponent, openSeconds);
        }
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf finishPlayOnQueueWithFile:file error:error openRequestId:openId];
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(_openTimeoutSnapshot.noProgressSeconds * NSEC_PER_SEC)), _queue, ^{
        [weakSelf fileOpenDeadlineDueForRequest:openId];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSlowOpenIndicatorDelaySeconds * NSEC_PER_SEC)), _queue, ^{
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf) {
            VibePlaybackRequest *request = [strongSelf->_pendingRequest markSlowForRequest:openId];
            if (request) {
                [strongSelf notifyDidBeginLoadingForRequest:request];
            }
        }
    });
}

- (void)finishPlayOnQueueWithFile:(AVAudioFile *)file error:(NSError *)error openRequestId:(uint64_t)openId {
    // Reject late deliveries before querying the device or replacing a parked
    // settlement. An obsolete open must not displace the current one's block.
    if (![_pendingRequest isCurrentRequest:openId]) {
        return;
    }
#if TARGET_OS_OSX
    // Bit-perfect output: a format switch stops the engine, which would cut a
    // still-fading outgoing node mid-waveform. Park until the outgoing audio
    // is silent, then re-enter verbatim; consumeRequest: below drops a
    // re-entry a newer play or a stop has superseded, so no generation is
    // needed. Last writer wins if the same-path prefetch race delivers twice.
    if (_bitPerfectWanted && file && _activeRetiredOutputCount > 0
            && [self outputNeedsSwitchOnQueueForFile:file unknownNeedsSwitch:YES]) {
        [self preemptRetiredFadesOnQueue];
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Timeline: play %llu settlement parked until the outgoing fade is silent",
                self.loadingSubmittedPlayIdentifier);
#endif
        __weak AudioPlayer *weakSelf = self;
        _settlementWaiter = ^{
            [weakSelf finishPlayOnQueueWithFile:file error:error openRequestId:openId];
        };
        return;
    }
#endif
    VibePlaybackRequest *request = [_pendingRequest consumeRequest:openId];
    if (!request) {
        return; // Superseded by a newer play, or already timed out.
    }
    // The prefetch worker can win this request while its dedicated play claim
    // is still open. Whichever completion wins consumes the request and
    // detaches that claim; an identifier guard protects a newer play.
    [self cancelPlayOpenForRequest:openId];
    // If the interactive open won its same-path prefetch race, retire the
    // loser before a late result can make the new current track its successor.
    [self retirePrefetchOnQueueAtPoint:VibeAudioPrefetchAtPlaySettlement
                              playPath:request.path];
    AudioTrack *track = request.track;
    VibePendingPlaybackIntent startIntent = request.intent;
    NSTimeInterval startPosition = startIntent.position;
    BOOL startPaused = startIntent.paused;

#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Timeline: play %llu open settled for %@, %.0f Hz, %lld frames, error %@",
            request.submittedPlayIdentifier, track.url.lastPathComponent,
            file.processingFormat.sampleRate, file.length, error);
#endif
    if (!file || file.length <= 0) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorFileOpenFailed,
                [NSString stringWithFormat:@"Could not open %@", track.url.lastPathComponent], error, track.url)
               forSubmittedPlay:request.submittedPlayIdentifier];
        return;
    }

#if TARGET_OS_OSX
    // Nothing is audible now — either nothing was counted, or the park above
    // ran — so the switch may stop the engine, which it does itself. Both
    // gate themselves on the mode.
    [self prepareOutputOnQueueForFile:file];
    [self ensureVarispeedOnQueue]; // a toggle during the open may have changed the chain
    if (_bitPerfectWanted) {
        _incomingFadeMilliseconds = kFadeDurationMilliseconds;
    }
#endif
    AVAudioPlayerNode *node = [self attachConnectedNodeForFile:file];
    if (!node) {
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed,
                [NSString stringWithFormat:@"Could not play %@ (unsupported format)",
                                           track.url.lastPathComponent], nil, track.url)
               forSubmittedPlay:request.submittedPlayIdentifier];
        return;
    }

    double sampleRate = file.processingFormat.sampleRate;
    AVAudioFramePosition startFrame = VibeClampedStartFrame(startPosition, sampleRate, file.length);
    NSTimeInterval framePosition = (NSTimeInterval)startFrame / sampleRate;

    [self scheduleFile:file onNode:node fromFrame:startFrame];
    // Silent for the fade-in below; at unity for bit-perfect output, which has none.
    node.volume = [self leavesSamplesUntouchedOnQueue] ? 1 : 0;

    if (startPaused) {
        // A scheduled, silent, never-played node is exactly what a pause
        // leaves behind, so playPause's resume branch takes it from here.
        [self publishPlaybackState:VibePlayerStatePaused node:node file:file
                      segmentStart:startFrame position:framePosition];
        // Paused is idle; see completePauseOfNode:. The engine may be running
        // from the track this one replaced, and nothing else will stop it.
        [self scheduleEngineIdleStopOnQueue];
    }
    else {
        NSError *startError = nil;
        if (![self startEngineAndPlayNode:node error:&startError]) {
            [self abandonNodeAfterFailedStart:node];
            [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed,
                    @"Could not start audio engine", startError, track.url)
                   forSubmittedPlay:request.submittedPlayIdentifier];
            return;
        }

        [self publishPlaybackState:VibePlayerStatePlaying node:node file:file
                      segmentStart:startFrame position:framePosition];

        // Fade the new track in from silence: its first frame is rarely a zero
        // crossing, so starting at full volume clicks. It reuses the current
        // ramp generation rather than a fresh one, so it rises in step with the
        // outgoing track's fade-out — a real crossfade — and neither ramp
        // cancels the other. The length matches that fade-out (playOnQueue:),
        // and the curve follows the length, so both sides ride equal power.
        [self rampNodeAsync:node step:1 from:0 to:1.0
               milliseconds:(_incomingFadeMilliseconds ?: kFadeDurationMilliseconds)
                 generation:_rampGeneration completion:nil];
    }

    self.currentTrack = track;
    _activeSubmittedPlayIdentifier = request.submittedPlayIdentifier;
    track.duration = self.duration;
    if ([self submittedPlayIsCurrent:request.submittedPlayIdentifier]) {
        [self playbackDidSucceedForPrefetchOnQueue];
    }
    else {
        [self terminallyRetirePrefetchRequestOnQueue];
    }
    // Dropped for a superseded submission, for the same reason its error is:
    // the shell's own guard compares the track, and a replay of the SAME row
    // is the same AudioTrack, so a start that belongs to the previous play
    // reads as current. Acting on it re-runs didStartPlaying:'s whole tail —
    // including the successor prefetch whose acknowledgement releases the
    // metadata materialization hold, stamped with the NEWER play's generation because that
    // play was submitted while this callback was still travelling. The
    // background lane then resumes against an open the user is still waiting
    // on. Measured: a background download beginning 15ms into it.
    uint64_t settledPlay = request.submittedPlayIdentifier;
#if VIBE_VERBOSE_LOGGING
    uint64_t deliveredAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), settledSegment = _segmentGeneration;
#endif
    run_on_main_thread({
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Timeline: play %llu segment %llu didStartPlaying main delivery %.1f ms, %@",
                settledPlay, settledSegment, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - deliveredAt) / 1e6,
                [self submittedPlayIsCurrent:settledPlay] ? @"accepted" : @"dropped: newer play");
#endif
        if (![self submittedPlayIsCurrent:settledPlay]) {
            LogInfo(@"Dropping didStartPlaying for superseded play %llu", settledPlay);
            return;
        }
        [self.delegate audioPlayer:self didStartPlaying:track];
    });
}

// One logical deadline: the firing checks the effective deadline against the
// progress the open has shown, re-arms itself for the remainder when a sample
// has pushed it out, and abandons only when genuinely due. Progress can only
// extend (AudioFileOpenTimeoutMath.h), so re-arming never shortens anything, and a
// stale firing for a superseded or landed open fails the identifier check
// before it can read another request's stamps.
- (void)fileOpenDeadlineDueForRequest:(uint64_t)openId {
    VibePlaybackRequest *pending = _pendingRequest.currentRequest;
    if (!pending || pending.identifier != openId) {
        return; // The open landed in time, or a newer play superseded it.
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval remaining = VibeAudioOpenDeadlineRemaining(
            now, _openSubmittedUptime, _openLastPositiveMovementUptime,
            _openTimeoutSnapshot);
    if (remaining > 0) {
        __weak AudioPlayer *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), _queue, ^{
            [weakSelf fileOpenDeadlineDueForRequest:openId];
        });
        return;
    }
    VibePlaybackRequest *request = [_pendingRequest consumeRequest:openId];
    if (!request) {
        return;
    }
    [self cancelPlayOpenForRequest:openId];
    // If materialization was still running it is cancelled. If the worker had
    // entered AVAudioFile, its path claim stays registered until that call
    // returns, and a same-path retry rebinds to it.
    AudioTrack *track = request.track;
    // Useful in the log, but not a recovery instruction: a timeout never
    // changes metadata priority or continues playback intent behind the error.
    BOOL madeProgress = _openLastPositiveMovementUptime > _openSubmittedUptime;
    LogError(@"Timed out opening %@ (progress seen: %@)", track.url.path,
             madeProgress ? @"yes" : @"no");
    [self resetToStoppedStateOnQueue];
    NSError *timedOut = VibeAudioErrorForTrack(VibeAudioErrorFileOpenTimedOut,
            [NSString stringWithFormat:@"Timed out opening %@ — it may still be downloading from iCloud/Dropbox or the network may be unavailable",
                                       track.url.lastPathComponent], nil, track.url);
    [self sendDelegateError:timedOut forSubmittedPlay:request.submittedPlayIdentifier];
}

- (void)noteOpenProgressForOpenRequestIdentifier:(uint64_t)openRequestIdentifier {
    if (!openRequestIdentifier) {
        return;
    }
    dispatch_async(_queue, ^{
        VibePlaybackRequest *pending = self->_pendingRequest.currentRequest;
        if (!pending || pending.identifier != openRequestIdentifier
                || self->_playOpenRequestId != openRequestIdentifier) {
            return;
        }
        self->_openLastPositiveMovementUptime = NSProcessInfo.processInfo.systemUptime;
    });
}

- (void)prefetchTrack:(AudioTrack *)track {
    dispatch_async(_queue, ^{
        AudioTrack *target = VibeAudioPrefetchDepthAllowsSuccessor(
                self->_loadingConfiguration.prefetchDepth) ? track : nil;
        [self prefetchOnQueue:target];
    });
}

// Marks playback fully stopped after a failure, so that isPlaying and duration
// report reality and the play button can recover.
- (void)resetToStoppedStateOnQueue {
    // Invalidate any in-flight open. After an unrelated failure resets to
    // Stopped — a device switch failing mid-Loading, say — a still-pending
    // open must not land later and start playback out of an errored or stopped
    // UI. The request's unique identifier makes every late delivery a no-op.
    [_pendingRequest invalidate];
    _activeSubmittedPlayIdentifier = 0;
    [self cancelPlayOpenOnQueue];
    [self retirePrefetchOnQueueAtPoint:VibeAudioPrefetchAtAbandonment
                              playPath:nil];
    [self clearGaplessOnQueue]; // any queued segment died with the node
    // Detach the varispeed attached for the failed track.
    // Otherwise it stays attached across Stopped until the next play or stop;
    // stopOnQueue arrives here with it already nil. The detach must not throw,
    // because this can run right after a failed connect left it
    // half-connected.
    if (_varispeed) {
        [self detachNodeAfterFailedConnect:_varispeed];
        _varispeed = nil;
    }
    // Stop and every failure path land here — a crossfade whose incoming open
    // failed included — so the outgoing fade must not ring on for up to the
    // full crossfade length.
    [self preemptRetiredFadesOnQueue];
    [self publishPlaybackState:VibePlayerStateStopped node:nil file:nil segmentStart:0 position:0];
#if TARGET_OS_OSX
    // A reset may be inside a device mutation whose rollback is still owed.
    // Do not retry a failed saved-device bind, even on a later queue turn.
    if (!_pendingSavedDeviceLookupInFlight && !_terminating) {
        dispatch_async(_queue, ^{ [self resolvePendingSavedOutputDeviceOnQueue]; });
    }
#endif
    // Release the output device once genuinely idle. A quick follow-up play,
    // such as auto-advance past a bad file, reuses the running engine.
    [self scheduleEngineIdleStopOnQueue];
}

- (void)segmentDidCompleteWithGeneration:(uint64_t)generation {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Callback: play %llu segment completed captured %llu current %llu, state %ld (%@)",
            [self diagnosticPlayIdentifierOnQueue], generation, _segmentGeneration, (long)_state,
            generation != _segmentGeneration ? @"dropped: superseded"
            : _gaplessQueued ? @"accepted: gapless handover" : @"accepted: track end");
#endif
    if (generation != _segmentGeneration) {
        return; // Stale: a stop, seek, skip or device switch superseded this segment.
    }
    if (_gaplessQueued) {
        // Not an end: the next track's segment is queued behind this one and
        // already sounding. Splice, don't tear down.
        [self promoteGaplessOnQueue];
        return;
    }
    [self finishPlaybackOnQueue];
}

// The shared terminus for "the current track is done": the natural segment
// completion above and an explicit -finishCurrentTrack both land here, on
// _queue. It marks the player Stopped, tears the finished node down and
// notifies the delegate, whose handler drives auto-advance or the
// end-of-playlist stop. The engine stop is deferred so that the auto-advance
// play, which arrives within milliseconds through didFinishPlaying → next,
// reuses the running engine rather than paying an output-unit stop and start
// on every consecutive-track transition.
- (void)finishPlaybackOnQueue {
    // A device recovery failure can reset the active submission below.
    AudioTrack *track = self.currentTrack;
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    // Un-armed material (format mismatch, crossfade on) dies with the node;
    // the next track's play re-acquires through its own prefetch.
    [self clearGaplessOnQueue];
    AVAudioPlayerNode *finishedNode =
            [self unpublishNodeOnQueueEnteringTerminalState:VibePlayerStateStopped];
    if (finishedNode) {
        [finishedNode stop];
        [_engine detachNode:finishedNode];
    }
    [self refreshOutputAudioActiveOnQueue];
#if TARGET_OS_OSX
    [self resolvePendingSavedOutputDeviceOnQueue];
#endif
    [self scheduleEngineIdleStopOnQueue];
    // Snapshot before dispatching. If the track has changed by the time the
    // block runs on main, this end event is stale and must be dropped.
    _activeSubmittedPlayIdentifier = 0;
#if VIBE_VERBOSE_LOGGING
    uint64_t deliveredAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), settledSegment = _segmentGeneration;
#endif
    run_on_main_thread({
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Timeline: play %llu segment %llu didFinishPlaying main delivery %.1f ms, %@",
                owningSubmittedPlayIdentifier, settledSegment, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - deliveredAt) / 1e6,
                track && self.currentTrack == track && [self submittedPlayIsCurrent:owningSubmittedPlayIdentifier]
                        ? @"accepted" : @"dropped: track or submission changed");
#endif
        if (!track || self.currentTrack != track
                || ![self submittedPlayIsCurrent:owningSubmittedPlayIdentifier]) {
            return;
        }
        [self.delegate audioPlayer:self didFinishPlaying:track];
    });
}

- (void)finishCurrentTrack {
    // Snapshot the caller's intent: a gapless boundary can promote the next
    // track before the block runs, and finishing then would end the track the
    // skip meant to *reach* — one skip landing two tracks ahead. (The
    // mid-fade flavor of the same race is caught by the _file check below.)
    AudioTrack *intendedTrack = self.currentTrack;
    dispatch_async(_queue, ^{
        if (self.currentTrack != intendedTrack) {
            return; // the boundary already advanced playback; the skip's goal is met
        }
        os_unfair_lock_lock(&self->_stateLock);
        VibePlayerState state = self->_state;
        AVAudioPlayerNode *node = self->_node;
        AVAudioFile *file = self->_file;
        os_unfair_lock_unlock(&self->_stateLock);
        // Only a live track can finish. Stopped has nothing to do, and Loading
        // has no node yet, so both are no-ops. The skip path never reaches
        // here while loading anyway, since the duration is 0.
        if (state != VibePlayerStatePlaying && state != VibePlayerStatePaused) {
            return;
        }
        uint64_t rampGen = [self preemptRampsOnQueue];
        if (state == VibePlayerStatePlaying && node && self->_engine.isRunning) {
            // A natural end is already silent, but this path can arrive at
            // full volume, on a forward skip past the end, so fade first or
            // the bare [node stop] clicks. The fade is the generation-tagged
            // ramp, so transport during the window preempts the pending
            // finish cleanly: a pause pauses in place instead of advancing,
            // and a new play retires the node with a single volume driver.
            // The node is still _node here, so every preemptor takes it over
            // and preemption cannot strand it audible. _segmentGeneration is
            // deliberately not bumped until the finish lands: a cancelled
            // finish leaves the scheduled segment's completion live, so the
            // natural track end still fires after a resume.
            __weak AudioPlayer *weakSelf = self;
            [self rampNodeAsync:node step:1 from:node.volume to:0 generation:rampGen completion:^{
                AudioPlayer *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                // Preempted — a play, pause, seek, stop or device switch owns
                // playback now — or the track ended naturally mid-fade and
                // finishPlaybackOnQueue already ran and cleared _node. Either
                // way this finish must not fire: didFinishPlaying: is
                // exactly-once, and the node's teardown belongs to whoever
                // superseded it.
                if (rampGen != strongSelf->_rampGeneration || strongSelf->_node != node) {
                    return;
                }
                if (strongSelf->_file != file) {
                    // The boundary promoted mid-fade: the splice already
                    // advanced playback into the next track, which is what
                    // this skip wanted. Finishing now would kill the promoted
                    // track and advance a second time; instead restore the
                    // volume the fade took.
                    [strongSelf rampNodeAsync:node step:1 from:node.volume to:1.0
                                   generation:rampGen completion:nil];
                    return;
                }
                // [node stop] inside finishPlaybackOnQueue fires the scheduled
                // segment's completion; bump so it reads as stale.
                strongSelf->_segmentGeneration++;
                [strongSelf finishPlaybackOnQueue];
            }];
            return;
        }
        self->_segmentGeneration++; // the [node stop] below fires the segment's completion
        [self finishPlaybackOnQueue];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        [self stopOnQueue];
    });
}

- (void)stopOnQueue {
    _segmentGeneration++; // drop the scheduled segment's stop-fired completion
    [self preemptRampsOnQueue];

    // Pull the node/varispeed pair out of the live state, fade it to silence
    // if audible, and detach both.
    AVAudioUnitVarispeed *oldVarispeed = _varispeed;
    AVAudioPlayerNode *oldNode = [self unpublishNodeOnQueue];
    _varispeed = nil;

    // The declick minimum, never the crossfade length: a stop should land
    // immediately.
    [self retireNode:oldNode varispeed:oldVarispeed milliseconds:kFadeDurationMilliseconds];

    self.currentTrack = nil;
    // Supersede every open and park, publish Stopped, then schedule the engine
    // idle stop which releases the output device.
    [self resetToStoppedStateOnQueue];
}

- (void)playPause {
#if VIBE_VERBOSE_LOGGING
    uint64_t submittedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    LogInfo(@"Timeline: playPause submitted at %llu", submittedAt);
#endif
    dispatch_async(_queue, ^{
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Timeline: play %llu segment %llu playPause %llu admitted after %.1f ms, state %ld",
                [self diagnosticPlayIdentifierOnQueue], self->_segmentGeneration, submittedAt,
                (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - submittedAt) / 1e6, (long)self->_state);
#endif
        if (self->_state == VibePlayerStateLoading) {
            VibePlaybackRequest *request = [self->_pendingRequest togglePause];
            if (request) {
                [self mirrorLoadingRequest:request clearingSubmittedPlayIdentifier:0];
                [self notifyLoadingPausedForRequest:request];
            }
            return;
        }
        if (self->_state == VibePlayerStatePlaying) {
            if (self->_pausePending) {
                // A second press during the pause fade-out cancels the pending
                // pause and ramps back up. There is no delegate event, because
                // didPause never fired and the UI never left the playing
                // state.
                [self cancelPendingPauseOnQueue];
            }
            else {
                [self pauseOnQueue];
            }
            return;
        }
        else if (self->_state == VibePlayerStatePaused) {
            [self resumeOnQueue];
            return;
        }
        [self sendDelegateError:VibeAudioError(VibeAudioErrorNotPlaying, @"Nothing is playing", nil)];
    });
}

- (void)pause {
    dispatch_async(_queue, ^{
        [self pauseOnQueue];
    });
}

- (void)resume {
#if VIBE_VERBOSE_LOGGING
    uint64_t submittedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    LogInfo(@"Timeline: resume submitted at %llu", submittedAt);
#endif
    dispatch_async(_queue, ^{
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Timeline: play %llu segment %llu resume %llu admitted after %.1f ms, state %ld",
                [self diagnosticPlayIdentifierOnQueue], self->_segmentGeneration, submittedAt,
                (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - submittedAt) / 1e6, (long)self->_state);
#endif
        [self resumeOnQueue];
    });
}

- (BOOL)getPlaybackIntent:(VibePendingPlaybackIntent *)intent forTrack:(AudioTrack *)track {
    __block BOOL loaded = NO;
    [self runSyncOnQueue:^{
        if (self->_state == VibePlayerStateLoading) {
            VibePlaybackRequest *request = self->_pendingRequest.currentRequest;
            if (request && (!track || request.track == track)) {
                *intent = request.intent;
                loaded = YES;
            }
            return;
        }
        if ((!track || self.currentTrack == track) && (self->_state == VibePlayerStatePlaying
                || self->_state == VibePlayerStatePaused)) {
            *intent = VibePendingPlaybackIntentMake(
                    self->_pendingSeekPosition >= 0 ? self->_pendingSeekPosition : self.position,
                    self->_state == VibePlayerStatePaused || self->_pausePending);
            loaded = YES;
        }
    }];
    return loaded;
}

// Explicit desired-state transport. Unlike playPause, duplicate calls are
// no-ops, and the decision is made beside the mutable state on _queue rather
// than from a caller's stale snapshot.
- (void)pauseOnQueue {
    if (_state == VibePlayerStateLoading) {
        VibePlaybackRequest *request = [_pendingRequest setPausedIfChanged:YES];
        if (request) {
            [self mirrorLoadingRequest:request clearingSubmittedPlayIdentifier:0];
            [self notifyLoadingPausedForRequest:request];
        }
        return;
    }
    if (_state != VibePlayerStatePlaying || _pausePending) {
        return;
    }
    AVAudioPlayerNode *node = _node;
    if (!node) {
        return;
    }
    uint64_t rampGen = [self preemptRampsOnQueue]; // cancel any in-flight resume fade-in
    // A pause must silence a crossfade's outgoing tail too, not just the
    // current node.
    [self preemptRetiredFadesOnQueue];
    // Fade out asynchronously, then pause in the completion. The queue must
    // not block for the fade, or a skip or seek issued right behind a pause
    // would stall behind it. The state stays Playing through the fade, because
    // the node really is still rendering.
    _pausePending = YES;
    __weak AudioPlayer *weakSelf = self;
    [self rampNodeAsync:node step:1 from:node.volume to:0 generation:rampGen completion:^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        // A preempted ramp still reaches this completion (see rampNodeAsync:),
        // so the node and state checks alone are not enough. Resume and seek
        // both bump _rampGeneration while leaving node and state untouched,
        // and pausing under them would fight the operation that now owns
        // volume and state.
        if (rampGen != strongSelf->_rampGeneration
                || strongSelf->_node != node || strongSelf->_state != VibePlayerStatePlaying) {
            return; // A play, stop, seek, resume or device switch superseded the pause.
        }
        // A superseded completion must not clear a newer pause, including one
        // carried by the internal seek that unqueues a gapless segment.
        strongSelf->_pausePending = NO;
        [strongSelf completePauseOfNode:node];
    }];
}

- (void)resumeOnQueue {
    if (_state == VibePlayerStateLoading) {
        VibePlaybackRequest *request = [_pendingRequest setPausedIfChanged:NO];
        if (request) {
            [self mirrorLoadingRequest:request clearingSubmittedPlayIdentifier:0];
            [self notifyLoadingPausedForRequest:request];
        }
        return;
    }
    if (_state == VibePlayerStatePlaying) {
        // The state remains Playing during the pause fade. An explicit resume
        // arriving in that window owns the desired state and dissolves it.
        [self cancelPendingPauseOnQueue];
        return;
    }
    if (_state != VibePlayerStatePaused || !_node) {
        return;
    }
    AVAudioPlayerNode *node = _node;
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    NSError *startError = nil;
    if (![self startEngineAndPlayNode:node error:&startError]) {
        // startEngineAndPlayNode: cancelled the pending idle stop at entry;
        // the state stays Paused, so re-arm it or a running engine holds the
        // output device forever.
        [self scheduleEngineIdleStopOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                @"Could not resume playback", startError)
               forSubmittedPlay:owningSubmittedPlayIdentifier];
        return;
    }
    // Re-publish rather than changing _state alone, so iOS's player-owned
    // recovery sampler restarts when rendering resumes.
    [self publishPlaybackState:VibePlayerStatePlaying node:node file:_file
                  segmentStart:_segmentStartFrame position:self.pausedPosition];
    uint64_t rampGen = [self preemptRampsOnQueue];
    [self rampNodeAsync:node step:1 from:node.volume to:1.0 generation:rampGen completion:nil];
    AudioTrack *track = self.currentTrack;
#if VIBE_VERBOSE_LOGGING
    uint64_t deliveredAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), resumedSegment = _segmentGeneration;
#endif
    run_on_main_thread({
#if VIBE_VERBOSE_LOGGING
        LogInfo(@"Timeline: play %llu segment %llu didResumePlaying main delivery %.1f ms, current submission %d",
                owningSubmittedPlayIdentifier, resumedSegment,
                (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - deliveredAt) / 1e6,
                [self submittedPlayIsCurrent:owningSubmittedPlayIdentifier]);
#endif
        [self.delegate audioPlayer:self didResumePlaying:track];
    });
}

- (void)cancelPendingPauseOnQueue {
    if (!_pausePending || !_node) {
        return;
    }
    AVAudioPlayerNode *node = _node;
    uint64_t rampGen = [self preemptRampsOnQueue];
    [self rampNodeAsync:node step:1 from:node.volume to:1.0 generation:rampGen completion:nil];
}

// Runs on _queue. It captures the position, pauses the node and publishes the
// Paused state. The capture happens after any fade, since the node keeps
// rendering through the ramp, but before [node pause], because once paused
// playerTimeForNodeTime: stops reporting.
- (void)completePauseOfNode:(AVAudioPlayerNode *)node {
    NSTimeInterval position = self.position;
    // The unclamped rendered position, read before [node pause] stops
    // playerTime reporting; see _pausedRawPosition.
    NSTimeInterval rawPosition = position;
    @try {
        AVAudioTime *nodeTime = node.lastRenderTime;
        // Guarded on validity like the position getter: an invalid reading
        // means no reading, and asking anyway error-logs per call.
        AVAudioTime *playerTime = nodeTime && (nodeTime.sampleTimeValid || nodeTime.hostTimeValid)
                ? [node playerTimeForNodeTime:nodeTime] : nil;
        double sampleRate = _file.processingFormat.sampleRate;
        if (playerTime && playerTime.sampleTimeValid && sampleRate > 0) {
            rawPosition = (NSTimeInterval)(_segmentStartFrame + playerTime.sampleTime) / sampleRate;
        }
    }
    @catch (NSException *exception) {
    }
    [node pause];
    [self publishPlaybackState:VibePlayerStatePaused node:node file:_file segmentStart:_segmentStartFrame position:position];
    _pausedRawPosition = rawPosition; // after the publish, which resets it to the clamped value
    // Paused is idle: without this the engine renders silence and holds the
    // output device for as long as the user stays paused. Resume restarts it
    // through startEngineAndPlayNode:, which also dissolves this pending stop.
    [self scheduleEngineIdleStopOnQueue];
#if TARGET_OS_OSX
    // The first moment a pause is silent, and so the first moment a wanted
    // device that came back while audio was playing may be adopted. Without
    // this it waited for the next stop.
    [self resolvePendingSavedOutputDeviceOnQueue];
#endif
    AudioTrack *track = self.currentTrack;
    run_on_main_thread({
        [self.delegate audioPlayer:self didPausePlaying:track];
    });
}

#pragma mark - Debug introspection
#if DEBUG
- (instancetype)initForManualRendering:(AVAudioFormat *)format enableFX:(BOOL)enableFX automatic:(BOOL)automatic delegate:(id<AudioPlayerDelegate>)delegate {
    NSParameterAssert(format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved);
    return [self initWithDeviceUID:@"" modelUID:@"" name:@"" enableFX:enableFX delegate:delegate
             loadingConfiguration:[AudioLoadingConfiguration productionConfiguration]
                       manualPump:[[VibeManualRenderPump alloc] initWithFormat:format automatic:automatic]];
}
- (AVAudioPCMBuffer *)debugRenderFrames:(AVAudioFrameCount)frames error:(NSError **)error {
    __block AVAudioPCMBuffer *buffer;
    __block NSError *failure;
    [self runSyncOnQueue:^{ buffer = [self->_manualPump renderFrames:frames error:&failure]; }];
    if (error) *error = failure;
    return buffer;
}
- (void)debugSetCapture:(void (^)(AVAudioPCMBuffer *))capture {
    [self runSyncOnQueue:^{ self->_manualPump.capture = capture; }];
}
- (void)debugBlockQueueForSeconds:(NSTimeInterval)seconds {
    dispatch_async(_queue, ^{ usleep((useconds_t)(MIN(10, MAX(0, seconds)) * 1e6)); });
}

- (void)debugShutdown {
    self.delegate = nil;
    [self runSyncOnQueue:^{
        self->_terminating = YES;
        [self stopOnQueue];
        [self->_manualPump cancel];
        [self->_engine stop];
    }];
}

// Debug-only: dump_audio_loading compares the three consumers' snapshots —
// the materialization coordinator's, the metadata cache's and this one — and
// nothing in the app reads the player's back. The read runs on _queue beside
// applyLoadingConfiguration:'s write.
- (AudioLoadingConfiguration *)loadingConfiguration {
    __block AudioLoadingConfiguration *configuration;
    [self runSyncOnQueue:^{
        configuration = self->_loadingConfiguration;
    }];
    return configuration;
}

- (BOOL)manualRenderingActive {
    return _manualPump != nil;
}

- (NSDictionary<NSString *, NSNumber *> *)debugEngineCounts {
    // Reading these off the queue would race every attach, detach and fade
    // retirement, which is exactly the code these numbers are meant to audit.
    __block NSDictionary *counts = nil;
    [self runSyncOnQueue:^{
        counts = @{@"attachedNodes": @(self->_engine.attachedNodes.count),
                   @"retiredFades": @(self->_retiredFades.count),
                   @"running": @(self->_engine.isRunning),
                   @"frames": @(self->_manualPump.renderedFrames),
                   @"varispeed": @(self->_varispeed != nil),
                   @"fxConnected": @(self->_fx.masterBusOutputNode != nil),
                   @"nodeVolume": @(self->_node.volume),
                   @"latency": @(self->_node.outputPresentationLatency),
                   @"varispeedLatency": @(self->_varispeed.latency),
                   @"mixerRate": @([self->_engine.mainMixerNode outputFormatForBus:0].sampleRate)};
    }];
    return counts;
}

static NSString *VibeAudioLevelNormalizationModeName(
        VibeAudioLevelNormalizationMode normalizationMode) {
    switch (normalizationMode) {
        case VibeAudioLevelNormalizationModeBalancedSpectrum:
            return @"balanced";
        case VibeAudioLevelNormalizationModeSharedSpectrum:
            return @"spectrum";
        case VibeAudioLevelNormalizationModeRelativeActivity:
        default:
            return @"activity";
    }
}

- (void)debugSetEqualizerNormalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode {
    if (normalizationMode != VibeAudioLevelNormalizationModeRelativeActivity
            && normalizationMode != VibeAudioLevelNormalizationModeSharedSpectrum
            && normalizationMode != VibeAudioLevelNormalizationModeBalancedSpectrum) {
        return;
    }
    [self runSyncOnQueue:^{
        if (self->_levelNormalizationMode == normalizationMode) {
            return;
        }
        if (self->_levelTap) {
            [self->_levelTap remove];
            self->_levelTap = nil;
        }
        self->_levelNormalizationMode = normalizationMode;
        if (self->_levelsWanted) {
            [self applyLevelTapOnQueue];
        }
    }];
}

- (NSDictionary<NSString *, id> *)debugEqualizerState {
    __block NSDictionary *state = nil;
    [self runSyncOnQueue:^{
        NSMutableDictionary<NSString *, id> *snapshot =
                [[self->_levelPublisher debugState] mutableCopy];
        snapshot[@"requested"] = @(self->_levelsWanted);
        snapshot[@"signalProbe"] = @(self->_signalProbeWanted); // beta builds' hold for a start's capture
        snapshot[@"tapObject"] = @(self->_levelTap != nil);
        snapshot[@"retiredOutputCount"] = @(self->_activeRetiredOutputCount);
        snapshot[@"outputAudioActive"] = @(self.outputAudioActive);
        snapshot[@"normalizationMode"] =
                VibeAudioLevelNormalizationModeName(self->_levelNormalizationMode);
        state = snapshot;
    }];
    return state;
}
#endif

#pragma mark - Crossfade

// Manual accessors so the write can keep the armed splice honest: raising the
// setting past the declick minimum unqueues an armed segment (the user now
// wants overlapped transitions, and playOnQueue:'s graze reasoning only holds
// at declick length), and lowering it back re-arms parked material that a
// closed gate left dormant.
@synthesize crossfadeMilliseconds = _crossfadeMilliseconds;

- (NSInteger)crossfadeMilliseconds {
    os_unfair_lock_lock(&_stateLock);
    NSInteger milliseconds = _crossfadeMilliseconds;
    os_unfair_lock_unlock(&_stateLock);
    return milliseconds;
}

- (void)setCrossfadeMilliseconds:(NSInteger)milliseconds {
    os_unfair_lock_lock(&_stateLock);
    _crossfadeMilliseconds = milliseconds;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        if (VibeGaplessArmAllowed(milliseconds)) {
            if (!self->_gaplessFile && self->_prefetchedFile && self->_prefetchedTrack) {
                // A raise dropped the splice material outright, so lowering
                // must reacquire the second handle off the parked prefetch;
                // maybeArmGaplessOnQueue alone only re-arms dormant material.
                [self maybeOpenGaplessFileForTrack:self->_prefetchedTrack
                                    prefetchedFile:self->_prefetchedFile];
            }
            [self maybeArmGaplessOnQueue];
        }
        else if (self->_gaplessQueued) {
            [self unscheduleGaplessOnQueue];
        }
    });
}

#pragma mark - Pitch

- (float)pitch {
    os_unfair_lock_lock(&_stateLock);
    float pitch = _pitch;
    os_unfair_lock_unlock(&_stateLock);
    return pitch;
}

- (void)setPitch:(float)pitch {
    os_unfair_lock_lock(&_stateLock);
    pitch = MAX(-_maxPitch, MIN(_maxPitch, pitch));
    _pitch = pitch;
    os_unfair_lock_unlock(&_stateLock);
    // The rate is an AU parameter, but touch the node only on the engine's
    // owning queue, as with every other graph mutation.
    dispatch_async(_queue, ^{
        [self applyPitchToVarispeedOnQueue:pitch];
    });
}

- (float)maxPitch {
    os_unfair_lock_lock(&_stateLock);
    float maxPitch = _maxPitch;
    os_unfair_lock_unlock(&_stateLock);
    return maxPitch;
}

- (void)setMaxPitch:(float)maxPitch {
    os_unfair_lock_lock(&_stateLock);
    _maxPitch = maxPitch;
    float pitch = MAX(-maxPitch, MIN(maxPitch, _pitch));
    _pitch = pitch;
    os_unfair_lock_unlock(&_stateLock);
    // Re-apply in case the narrower range clamped the current pitch.
    dispatch_async(_queue, ^{
        [self applyPitchToVarispeedOnQueue:pitch];
    });
}

#pragma mark - Helpers

// The play token slot is queue-confined. The request-specific form is what
// completion and timeout use: a delayed terminus must never detach a newer
// play's waiter.
- (void)cancelPlayOpenOnQueue {
    [_playOpenToken cancel];
    _playOpenToken = nil;
    _playOpenRequestId = 0;
}

- (void)cancelPlayOpenForRequest:(uint64_t)openId {
    if (_playOpenRequestId == openId) {
        [self cancelPlayOpenOnQueue];
    }
}

// Both halves in one critical section: the loading mirror a main-thread getter
// reads, and the retirement of the pre-Loading handoff, which only the play
// that set it may clear — a newer play submitted since owns it now.
- (void)mirrorLoadingRequest:(VibePlaybackRequest *)request
    clearingSubmittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    os_unfair_lock_lock(&_stateLock);
    _loadingTrack = request.track;
    _loadingStartPaused = request.intent.paused;
    _loadingSubmittedPlayIdentifier = request.submittedPlayIdentifier;
    if (_lastSubmittedPlayIdentifier == submittedPlayIdentifier) {
        _lastSubmittedPlayIdentifier = 0;
        _lastSubmittedPlayTrack = nil;
    }
    os_unfair_lock_unlock(&_stateLock);
}

- (void)clearSubmittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    os_unfair_lock_lock(&_stateLock);
    if (_lastSubmittedPlayIdentifier == submittedPlayIdentifier) {
        _lastSubmittedPlayIdentifier = 0;
        _lastSubmittedPlayTrack = nil;
    }
    os_unfair_lock_unlock(&_stateLock);
}

- (void)notifyDidBeginLoadingForRequest:(VibePlaybackRequest *)request {
    AudioTrack *track = request.track;
    uint64_t openRequestIdentifier = request.identifier;
    uint64_t submittedPlayIdentifier = request.submittedPlayIdentifier;
    run_on_main_thread({
        if (![self submittedPlayIsCurrent:submittedPlayIdentifier]) {
            LogInfo(@"Dropping didBeginLoading for superseded play %llu",
                    submittedPlayIdentifier);
            return;
        }
        [self.delegate audioPlayer:self
                  didBeginLoading:track
            openRequestIdentifier:openRequestIdentifier];
    });
}

- (void)notifyLoadingPausedForRequest:(VibePlaybackRequest *)request {
    AudioTrack *track = request.track;
    BOOL paused = request.intent.paused;
    uint64_t submittedPlayIdentifier = request.submittedPlayIdentifier;
    run_on_main_thread({
        if (![self submittedPlayIsCurrent:submittedPlayIdentifier]) {
            LogInfo(@"Dropping didChangeLoadingPaused for superseded play %llu",
                    submittedPlayIdentifier);
            return;
        }
        [self.delegate audioPlayer:self didChangeLoadingPaused:paused forTrack:track];
    });
}

// The writer model for the playback and position state, in one place.
//
// The player queue owns every engine and playback-state transition; _stateLock
// protects only the snapshot the main-thread getters read. This is the atomic
// FULL-TUPLE publisher: it writes state, node, file and the position fields in
// one lock acquisition, so a getter can never observe a torn combination such
// as a new state carrying the old track's position. A caller whose operation
// leaves a field untouched passes the current value through. The generation
// bump is structural: the position getter computes off-lock and writes
// _lastValidPosition back only if its snapshotted generation is still current.
//
// Three PARTIAL writers are permitted, and they are the whole set. Each holds
// _stateLock, and each is safe only because it never moves the position fields:
//
//   unpublishNodeOnQueue                       — clears _node alone.
//   unpublishNodeOnQueueEnteringTerminalState: — _state and _node together.
//   the position getter's writeback            — _lastValidPosition, under the
//                                                generation check (AudioPlayer+State.m).
//
// Anything else that writes this state, and anything at all that moves the
// position fields, must come through this publisher.
// Partial writer 1 of 3. Hands back what it removed so the caller can stop and
// detach the node off the lock, which is the point of unpublishing first: the
// position getter uses its snapshot of _node off the lock, and calling into a
// detached node raises.
- (AVAudioPlayerNode *)unpublishNodeOnQueue {
    _pendingSeekPosition = -1;
    os_unfair_lock_lock(&_stateLock);
    AVAudioPlayerNode *node = _node;
    _node = nil;
    os_unfair_lock_unlock(&_stateLock);
    return node;
}

// Partial writer 2 of 3. One acquisition, because a state that disagrees with
// the published node is exactly what the full-tuple publisher exists to
// prevent. The position fields are deliberately left where the last publish put
// them, so a track end keeps its playhead.
- (AVAudioPlayerNode *)unpublishNodeOnQueueEnteringTerminalState:(VibePlayerState)state {
    _pendingSeekPosition = -1;
    os_unfair_lock_lock(&_stateLock);
    _state = state;
    AVAudioPlayerNode *node = _node;
    _node = nil;
    os_unfair_lock_unlock(&_stateLock);
    return node;
}

- (void)publishPlaybackState:(VibePlayerState)state
                        node:(AVAudioPlayerNode *)node
                        file:(AVAudioFile *)file
                segmentStart:(AVAudioFramePosition)segmentStart
                    position:(NSTimeInterval)position {
    VibePlaybackRequest *request = state == VibePlayerStateLoading
            ? _pendingRequest.currentRequest : nil;
    if (node != _node || file != _file) {
        _pendingSeekPosition = -1;
    }
#if VIBE_VERBOSE_LOGGING
    AudioTrack *diagnosticTrack = self.currentTrack ?: self.loadingTrack;
    NSDictionary *diagnostic = state == VibePlayerStatePlaying && node && diagnosticTrack ? @{
        @"track": diagnosticTrack, @"play": @([self diagnosticPlayIdentifierOnQueue]),
        @"segment": @(_segmentGeneration), @"position": @(position),
        @"publishedAt": @(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) } : nil;
#endif
    os_unfair_lock_lock(&_stateLock);
#if VIBE_VERBOSE_LOGGING
    _positionDiagnostic = diagnostic;
#endif
    _node = node;
    _file = file;
    _segmentStartFrame = segmentStart;
    _pausedPosition = position;
    _pausedRawPosition = position; // completePauseOfNode: overrides with the unclamped value
    _lastValidPosition = position;
    _positionGeneration++;
    _state = state;
    if (state == VibePlayerStateLoading) {
        _loadingTrack = request.track;
        _loadingStartPaused = request.intent.paused;
        _loadingSubmittedPlayIdentifier = request.submittedPlayIdentifier;
    }
    else {
        _loadingTrack = nil;
        _loadingStartPaused = NO;
        _loadingSubmittedPlayIdentifier = 0;
    }
    os_unfair_lock_unlock(&_stateLock);
    [self refreshOutputAudioActiveOnQueue];
#if TARGET_OS_IOS
    uint64_t recoveryPositionGeneration = ++_recoveryPositionGeneration;
    if (state == VibePlayerStatePlaying) {
        [self scheduleRecoveryPositionSampleForGeneration:recoveryPositionGeneration];
    }
#endif
}

- (void)noteDisplayedPosition:(NSTimeInterval)position forTrack:(AudioTrack *)track {
#if VIBE_VERBOSE_LOGGING
    os_unfair_lock_lock(&_stateLock);
    NSDictionary *diagnostic = _positionDiagnostic;
    BOOL matches = track && diagnostic[@"track"] == track
            && [diagnostic[@"play"] unsignedLongLongValue] == _nextSubmittedPlayIdentifier
            && position > [diagnostic[@"position"] doubleValue];
    if (matches) _positionDiagnostic = nil;
    os_unfair_lock_unlock(&_stateLock);
    if (matches) {
        LogInfo(@"Timeline: play %@ segment %@ first advancing UI position %.3fs (published %.3fs), %.1f ms after state publication",
                diagnostic[@"play"], diagnostic[@"segment"], position, [diagnostic[@"position"] doubleValue],
                (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - [diagnostic[@"publishedAt"] unsignedLongLongValue]) / 1e6);
    }
#endif
}

// Output liveness is deliberately narrower than transport intent. Loading has
// no current node, but remains active while a retired crossfade is audibly
// finishing; a pause stays active through its fade because the state remains
// Playing until [node pause] lands. AudioFX does not expose wet-tail lifetime,
// so claiming one here would be a timer-shaped guess rather than actual state.
- (void)refreshOutputAudioActiveOnQueue {
    BOOL active = _engine.isRunning
            && ((_state == VibePlayerStatePlaying && _node != nil)
                || _activeRetiredOutputCount > 0);
    os_unfair_lock_lock(&_stateLock);
    BOOL changed = _outputAudioActive != active;
    _outputAudioActive = active;
    os_unfair_lock_unlock(&_stateLock);
#if TARGET_OS_OSX
    // Every state publication and fade completion funnels here, which makes
    // it the edge that keeps the bit-perfect report's "a track is playing"
    // input honest without a hook in each publisher. Off, it returns at once.
    [self publishBitPerfectReportOnQueue];
#endif
    if (!changed) {
        return;
    }
    run_on_main_thread({
        id<AudioPlayerDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(audioPlayer:didChangeOutputAudioActive:)]) {
            [delegate audioPlayer:self didChangeOutputAudioActive:active];
        }
    });
}

#if TARGET_OS_IOS
- (void)scheduleRecoveryPositionSampleForGeneration:(uint64_t)generation {
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kRecoveryPositionSampleIntervalSeconds * NSEC_PER_SEC)), _queue, ^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_recoveryPositionGeneration
                || strongSelf->_state != VibePlayerStatePlaying) {
            return;
        }
        // position stores only a valid playerTime result. If the engine has
        // already stopped, the cache remains the last frame sampled before it.
        (void)strongSelf.position;
        [strongSelf scheduleRecoveryPositionSampleForGeneration:generation];
    });
}
#endif

- (void)sendDelegateError:(NSError *)error {
    LogError(@"AudioPlayer Error: %@", error.localizedDescription);
    run_on_main_thread({
        [self.delegate audioPlayer:self error:error];
    });
}

// Whether a submission is still the newest one. Delivery sites call it on main
// from inside their delivery block, because what matters there is whether a
// newer play had been submitted by the time the callback actually ran. The
// gapless park also reads it on _queue before starting successor work.
//
// TRAP: the counter is _nextSubmittedPlayIdentifier, which only ever
// increments, and NOT _lastSubmittedPlayIdentifier, which looks like the same
// thing and is not — that one is the pre-Loading handoff, cleared to 0 the
// moment its play reaches Loading, so comparing against it reports EVERY
// settlement as superseded.
- (BOOL)submittedPlayIsCurrent:(uint64_t)submittedPlayIdentifier {
    os_unfair_lock_lock(&_stateLock);
    uint64_t newest = _nextSubmittedPlayIdentifier;
    os_unfair_lock_unlock(&_stateLock);
    return VibePlaybackDeliveryIsCurrent(submittedPlayIdentifier, newest);
}

// The play-path variant: an error belonging to a submission a newer play has
// already replaced is dropped rather than delivered.
//
// TRAP: the delegate cannot make this judgement itself, and its existing
// guards look like they can. A play failure is published as Stopped and its
// error hops to main; if the user re-plays the SAME row in the window before
// that hop lands, the shell sees a matching URL and a player that has not yet
// published Loading for the replacement — because that happens on the player
// queue, one hop later — so every guard it has says the error is current. It
// then tears down state the newer play had just set up. Measured: the shell's
// metadata materialization hold released 11ms after the replay's own open began, and the
// background lane started downloading against it.
//
// The identifier is what settles it, and it is exact rather than heuristic: a
// re-drop of a file already loading REBINDS its request and adopts the new
// submission's identifier, so a rebound request still matches and its error is
// still delivered.
- (void)sendDelegateError:(NSError *)error forSubmittedPlay:(uint64_t)submittedPlayIdentifier {
    LogError(@"AudioPlayer Error: %@", error.localizedDescription);
    run_on_main_thread({
        if (![self submittedPlayIsCurrent:submittedPlayIdentifier]) {
            LogInfo(@"Dropping error for superseded play %llu", submittedPlayIdentifier);
            return;
        }
        [self.delegate audioPlayer:self error:error];
    });
}


#if VIBE_VERBOSE_LOGGING
// Beta instrumentation (#47): the output's own render clock, checked every
// 50 ms while playing. A clock that stops means the device's IO stopped
// pulling audio — the one source of a frozen time counter that is neither the
// main thread nor a late first frame. Polled on _queue, like the first-render
// probe; reports both onset and recovery, including a missing render clock.
static void VibeWatchOutputRender(AudioPlayer *player) {
    static NSMutableArray *timers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ timers = [NSMutableArray array]; });
    __weak AudioPlayer *weakPlayer = player;
    __block AVAudioFramePosition lastSample = -1;
    __block uint64_t lastAdvance = 0, stalledSince = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, player->_queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        AudioPlayer *strongPlayer = weakPlayer;
        if (!strongPlayer) {
            return;
        }
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        os_unfair_lock_lock(&strongPlayer->_stateLock);
        BOOL playing = strongPlayer->_state == VibePlayerStatePlaying;
        os_unfair_lock_unlock(&strongPlayer->_stateLock);
        AVAudioTime *render = nil;
        if (playing && strongPlayer->_engine.isRunning) {
            @try {
                render = strongPlayer->_engine.outputNode.lastRenderTime;
            }
            @catch (NSException *exception) {
                render = nil; // instrumentation must never take playback down with it
            }
        }
        BOOL advancing = render.sampleTimeValid && render.sampleTime != lastSample;
        if (!playing || advancing) {
            if (stalledSince) {
                LogWarn(@"Stall: output render clock resumed/stopped after %.0f ms (play %llu, %@)",
                        (now - stalledSince) / 1e6, strongPlayer->_activeSubmittedPlayIdentifier,
                        strongPlayer.currentTrack.url.lastPathComponent);
            }
            lastSample = render.sampleTimeValid ? render.sampleTime : -1;
            lastAdvance = playing ? now : 0;
            stalledSince = 0;
        }
        else {
            if (!lastAdvance) lastAdvance = now;
            if (!stalledSince && now - lastAdvance > 200 * NSEC_PER_MSEC) {
                stalledSince = lastAdvance;
                LogWarn(@"Stall: output render clock stalled %.0f ms (play %llu, %@, engine %d, clock valid %d)",
                        (now - stalledSince) / 1e6, strongPlayer->_activeSubmittedPlayIdentifier,
                        strongPlayer.currentTrack.url.lastPathComponent, strongPlayer->_engine.isRunning,
                        render.sampleTimeValid);
#if TARGET_OS_OSX
                // Stuck in our render, or waiting for a device that stopped
                // asking: the IO thread's stack tells the two apart.
                thread_t io = VibeFindThread(nil, "com.apple.audio.IOThread.client");
                if (io == MACH_PORT_NULL) {
                    LogWarn(@"Stall stack: no audio IO thread exists");
                }
                else {
                    VibeSampleStack(io, @"audio IO thread", (now - stalledSince) / 1e6, nil);
                    mach_port_deallocate(mach_task_self(), io);
                }
#endif
            }
        }
    });
    dispatch_resume(timer);
    @synchronized (timers) {
        [timers addObject:timer];
    }
}
#endif

@end
