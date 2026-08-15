//
//  NSURL+AudioOpen.m
//  Vibe
//

#import "NSURL+AudioOpen.h"

#include <sys/stat.h>

@implementation NSURL (AudioOpen)

// TRAP: AVAudioFile — and ExtAudioFileOpenURL and AudioFileOpenURL under it —
// leaks a file descriptor on every attempt against a path the kernel opens but
// a decoder finds nothing in: a zero-length file, or a directory. The open
// fails, the descriptor stays, and nothing reclaims it; 300 attempts cost 300
// descriptors against a 256 soft limit. Merely unparseable content closes
// cleanly and needs no guard, so emptiness is the whole test.
//
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
