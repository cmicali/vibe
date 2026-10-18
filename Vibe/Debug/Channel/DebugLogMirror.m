//
//  DebugLogMirror.m
//  Vibe
//
//  --log-stderr mirrors every message to stderr, for a debug build on a real
//  iPhone: `log stream` has no device mode and idevicesyslog drops a
//  third-party subsystem, but stderr comes back over `devicectl ... --console`.
//

#import <Foundation/Foundation.h>

#if DEBUG

#import "CMMMacros.h"
#include <sys/time.h>

static void VibeLogToStderr(os_log_type_t type, NSString *message) {
    // os_log's timestamps do not reach the mirror.
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm now;
    localtime_r(&tv.tv_sec, &now);
    char stamp[16];
    strftime(stamp, sizeof(stamp), "%H:%M:%S", &now);
    fprintf(stderr, "%s.%03d %s\n", stamp, tv.tv_usec / 1000, message.UTF8String);
}

// Before main, so a message from the earliest launch code is mirrored too, as
// it was when the prefix header read the argument itself.
__attribute__((constructor)) static void VibeInstallStderrLogMirror(void) {
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--log-stderr"]) {
        CMMLogMirror = VibeLogToStderr;
    }
}

#endif
