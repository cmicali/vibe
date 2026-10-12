//
//  NetworkReadAhead.h
//  Vibe
//
//  The read-ahead of a file on a network mount. One thread per handle reads
//  the file into an availability with no part file (CloudFileAvailability),
//  and the handle's reads wait for their bytes there. A read the server fails
//  is retried until the handle goes. AudioFileHandle is the one caller.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioFile.h>

#include <errno.h>
#include <unistd.h>

@class CloudFileAvailability;

NS_ASSUME_NONNULL_BEGIN

// How often a read-ahead's open asks its `interrupted` block again. Its
// canceller wakes only a transfer (availabilityForURL:), never a read-ahead.
static const NSTimeInterval kVibeReadAheadOpenPollSeconds = 0.25;

// Whether `url` reads ahead: the kernel's mount table says its mount is a
// network one. *mount names that mount, for the log.
BOOL VibeNetworkReadAheadApplies(NSURL *url, NSString *_Nullable *_Nonnull mount);

// Waits while the read-ahead threads orphaned inside a read are at their
// limit. NO once `interrupted` answers YES.
BOOL VibeNetworkReadAheadAwaitRoom(NSString *name, BOOL (^interrupted)(void));

// Starts the file's read-ahead: an availability with no part file, and a
// thread that fills it. *end is the flags cell the handle shares with the
// thread, for VibeNetworkReadAheadHandleGone.
CloudFileAvailability *VibeNetworkReadAheadStart(NSURL *url, NSString *mount, uint8_t *_Nullable *_Nonnull end);

// Finishes a read-ahead's availability with a "closed" error. That ends its
// thread once its current read returns.
void VibeNetworkReadAheadClose(CloudFileAvailability *_Nullable availability, NSURL *url);

// The handle's dealloc: closes the availability, then marks the handle's end
// of `end`. A thread still inside a read is an orphan until it exits.
void VibeNetworkReadAheadHandleGone(CloudFileAvailability *_Nullable availability, NSURL *url, uint8_t *end);

// An open's own two failures, the same on the direct road and the read-ahead's.
// Inline, so the analyzer sees that each returns an error.
static inline NSError *VibeCouldNotOpenError(NSString *name, int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not open %@: %s", name, strerror(code)]}];
}

static inline NSError *VibeNoAudioError(NSString *name) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioFileUnsupportedFileTypeError
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ holds no audio data", name]}];
}

// A pread that a signal never cuts short. An error leaves errno set.
static inline ssize_t VibePread(int descriptor, void *buffer, size_t count, off_t offset) {
    ssize_t got;
    do {
        got = pread(descriptor, buffer, count, offset);
    } while (got < 0 && errno == EINTR);
    return got;
}

NS_ASSUME_NONNULL_END
