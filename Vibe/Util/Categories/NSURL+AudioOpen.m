//
//  NSURL+AudioOpen.m
//  Vibe
//

#import "NSURL+AudioOpen.h"

#import "AudioFileHandle.h"

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

// The open is the proof: the handle refuses anything but a nonempty regular
// file CoreAudio parses, and its length is the decoded frames it reports.
- (BOOL)validateAudioFileIsReadableAndHasContent {
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:self error:NULL];
    return handle.length > 0;
}

@end
