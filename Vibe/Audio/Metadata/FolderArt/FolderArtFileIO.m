//
//  FolderArtFileIO.m
//  Vibe
//

#import "FolderArtFileIO.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

// The lstat/O_NOFOLLOW rule these two share is in FolderArtFileIO.h.

BOOL VibeFolderArtFileInfo(NSString *path, unsigned long long *size) {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
            info.st_size <= 0 || (unsigned long long)info.st_size > kMaxArtFileBytes) {
        return NO;
    }
    if (size) {
        *size = (unsigned long long)info.st_size;
    }
    return YES;
}

// TRAP: O_NONBLOCK belongs on the *open* and nowhere else. It keeps a FIFO or a
// device named cover.jpg from wedging the resolver on the open itself — S_ISREG
// cannot be tested until that open returns. Left set across the reads it means
// something else entirely: a regular file whose bytes are not resident answers
// EAGAIN, which says nothing about the image.
NSData *VibeReadFolderArt(NSString *path) {
    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) {
        return nil;
    }
    struct stat info;
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
            (unsigned long long)info.st_size > kMaxArtFileBytes) {
        close(descriptor);
        return nil;
    }
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) < 0) {
        // The reads would answer EAGAIN instead of blocking, indistinguishable
        // from a real failure. Give up; the caller's retry budget covers it.
        close(descriptor);
        return nil;
    }
    NSUInteger length = (NSUInteger)info.st_size;
    void *bytes = malloc(length);
    if (!bytes) {
        close(descriptor);
        return nil;
    }
    NSUInteger offset = 0;
    while (offset < length) {
        ssize_t count = read(descriptor, (char *)bytes + offset, length - offset);
        if (count > 0) {
            offset += (NSUInteger)count;
        }
        else if (count < 0 && errno == EINTR) {
            continue;
        }
        else {
            break;
        }
    }
    close(descriptor);
    if (offset != length) {
        free(bytes);
        return nil;
    }
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}