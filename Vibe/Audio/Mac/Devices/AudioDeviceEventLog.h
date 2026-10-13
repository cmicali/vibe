//
//  AudioDeviceEventLog.h
//  Vibe
//
//  Beta instrumentation: the "HAL:" device event log. It follows
//  AudioDeviceManager's published snapshot, watches each device and its first
//  output stream, and logs every watched property change with its new value.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

@class AudioDevice;

NS_ASSUME_NONNULL_BEGIN

#if VIBE_VERBOSE_LOGGING
@interface AudioDeviceEventLog : NSObject

// Register with a NULL delivery queue: the callback copies each address and
// queues its read/log here, so even a busy log queue cannot hold the IO thread.
+ (AudioObjectPropertyListenerBlock)listenerForObject:(AudioObjectID)object
                                               name:(NSString *)name queue:(dispatch_queue_t)queue;

// Call it only on AudioDeviceManager's refresh queue, with each published
// snapshot. The first call creates the log queue and watches the system object.
- (void)watchDevices:(NSArray<AudioDevice *> *)devices;

@end
#endif

NS_ASSUME_NONNULL_END
