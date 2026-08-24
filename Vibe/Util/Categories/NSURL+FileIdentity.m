//
//  NSURL+FileIdentity.m
//  Vibe
//

#import "NSURL+FileIdentity.h"

#import <sys/stat.h>

@implementation NSURL (FileIdentity)

- (BOOL)vibeRefersToSameFileAsURL:(NSURL *)otherURL {
    if (!self.isFileURL || !otherURL.isFileURL) {
        return NO;
    }

    NSURL *firstStandardURL = self.URLByStandardizingPath;
    NSURL *secondStandardURL = otherURL.URLByStandardizingPath;
    NSString *firstStandardPath = firstStandardURL.path;
    NSString *secondStandardPath = secondStandardURL.path;
    if (firstStandardPath && [firstStandardPath isEqualToString:secondStandardPath]) {
        return YES;
    }

    NSString *firstResolvedPath = firstStandardURL.URLByResolvingSymlinksInPath.path;
    NSString *secondResolvedPath = secondStandardURL.URLByResolvingSymlinksInPath.path;
    if (firstResolvedPath && [firstResolvedPath isEqualToString:secondResolvedPath]) {
        return YES;
    }

    const char *firstFileSystemPath = self.fileSystemRepresentation;
    const char *secondFileSystemPath = otherURL.fileSystemRepresentation;
    if (!firstFileSystemPath || !secondFileSystemPath) {
        return NO;
    }
    struct stat firstStat;
    struct stat secondStat;
    return stat(firstFileSystemPath, &firstStat) == 0 &&
            stat(secondFileSystemPath, &secondStat) == 0 &&
            firstStat.st_dev == secondStat.st_dev &&
            firstStat.st_ino == secondStat.st_ino;
}

@end
