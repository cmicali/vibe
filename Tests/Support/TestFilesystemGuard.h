// TestFilesystemGuard.m's in-memory defaults store, for a test that needs a
// fresh one of its own rather than the process's standard one.

#import <Foundation/Foundation.h>

@interface VibeTestUserDefaults : NSUserDefaults
@end
