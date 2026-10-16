// TestFilesystemGuard.m's per-process root and in-memory defaults store, and
// the one run-loop wait the harnesses share. Every test target compiles it.

#import <Foundation/Foundation.h>

// The process's own directory under the temp directory. The guard removes it
// at exit, and a later run removes it after a crash.
FOUNDATION_EXTERN NSString *VibeTestProcessRoot(void);

// The in-memory defaults store, for a test that needs a fresh one of its own
// rather than the process's standard one.
@interface VibeTestUserDefaults : NSUserDefaults
@end

// Spins the current run loop until the condition holds, up to the hang guard.
static inline BOOL VibeSpinUntil(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow < 0) {
            return NO;
        }
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}

// A negative check's window. Short, since every pass runs its full length.
static const NSTimeInterval kVibeTestNegativeWindow = 0.2;

// Spins the current run loop for a fixed window, for a negative check. Zero
// runs one turn, which delivers what is already queued on main.
static inline void VibeSpinFor(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
    } while (until.timeIntervalSinceNow > 0);
}
