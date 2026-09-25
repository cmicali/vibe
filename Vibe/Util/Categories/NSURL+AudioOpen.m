//
//  NSURL+AudioOpen.m
//  Vibe
//

#import "NSURL+AudioOpen.h"

#include <sys/stat.h>

@implementation NSURL (AudioOpen)

// TRAP: st_size, never st_blocks or NSURLFileAllocatedSizeKey. An evicted
// iCloud or Dropbox file is dataless — true logical size, zero allocated
// blocks — so an allocation-based test would reject every cloud-hosted track.
// stat() reads that metadata locally and never materializes the file.
- (BOOL)isEmptyOrDirectory {
    if (!self.isFileURL) {
        return NO;
    }
    struct stat info;
    if (stat(self.fileSystemRepresentation, &info) != 0) {
        return NO; // unstattable: let the real open report why
    }
    return S_ISDIR(info.st_mode) || info.st_size == 0;
}

@end
