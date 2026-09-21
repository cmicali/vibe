//
//  AudioDeviceManager.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import "AudioDevice.h"

NS_ASSUME_NONNULL_BEGIN

// Callbacks are delivered on the main thread in the common run-loop modes, so
// they also fire while a menu is tracking (letting an open devices menu
// refresh on hotplug).
@protocol AudioDeviceManagerObserver <NSObject>
@optional
- (void)systemDefaultOutputDeviceDidChange;
- (void)audioOutputDevicesDidChange;
@end

@interface AudioDeviceManager : NSObject

+ (AudioDeviceManager *)sharedInstance;

// Controlled enumeration keeps the production queue, snapshot, waiter and
// retry policy. Nil enumerator uses HAL and registers process-lifetime listeners;
// an injected enumerator supplies changes through refreshOutputDevicesWithCompletion:.
- (instancetype)initWithEnumerator:(NSArray<AudioDevice *> * _Nullable (^_Nullable)(BOOL acceptPartial))enumerator
                     retryScheduler:(void (^_Nullable)(NSTimeInterval delay, dispatch_block_t retry))scheduler;
// Completion runs on the refresh queue, after publication and resolution waiters.
- (void)refreshOutputDevicesWithCompletion:(void (^)(BOOL published))completion;

// Observers are held weakly; add/remove may be called from any thread.
- (void)addObserver:(id<AudioDeviceManagerObserver>)observer;
- (void)removeObserver:(id<AudioDeviceManagerObserver>)observer;

// Snapshot of the current output devices, served from a cache the HAL
// listeners keep fresh (refreshed on a background queue BEFORE observers are
// notified, so a change callback reads the post-change list). Cheap on the
// main thread after first use — no per-call HAL enumeration. A first call
// waits at most 250ms for asynchronous listener setup and its
// post-registration sweep on every thread; an unavailable HAL therefore
// yields the last snapshot rather than blocking an arbitrary serial queue.
- (NSArray<AudioDevice *> *)outputDevices;

// Whether deviceId is missing from a snapshot that actually exists. NO while
// none has been published — during setup, or while a HAL failure is retrying —
// because `outputDevices` answers @[] for both that and a genuinely empty
// system. Every caller that treats absence as REMOVAL, and so falls back to
// System Output and persists it, must ask this rather than the getter.
- (BOOL)knowsOutputDeviceIsAbsent:(NSInteger)deviceId;

// Resolves against the first successful device snapshot without blocking the
// caller. UID wins; name is the compatibility fallback for older settings.
// If setup is temporarily unavailable, the request remains pending until a
// later refresh succeeds. Completion runs on the manager's refresh queue.
- (void)resolveOutputDeviceForUID:(NSString *)uid
                              name:(NSString *)name
                        completion:(void (^)(AudioDevice * _Nullable device))completion;

- (nullable AudioDevice *)outputDeviceForId:(NSInteger)deviceId;

// The published snapshot, or nil when none exists yet — WITHOUT waiting on
// listener setup, unlike outputDevices and publishedOutputDevices. For the
// player queue, which must never block on the HAL: an unavailable coreaudiod
// answers nil here rather than stalling playback for the setup ceiling.
- (nullable NSArray<AudioDevice *> *)cachedOutputDevices;

// The one matching rule for a saved device: UID wins, name is the fallback for
// settings older than the UID, and an empty UID never matches by UID.
+ (nullable AudioDevice *)deviceForUID:(nullable NSString *)uid
                                  name:(nullable NSString *)name
                             inDevices:(NSArray<AudioDevice *> *)devices;

@end

NS_ASSUME_NONNULL_END
