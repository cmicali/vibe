//
//  NSURL+AudioOpen.m
//  Vibe
//

#import "NSURL+AudioOpen.h"

@implementation NSURL (AudioOpen)

// stat() never materializes the file.
- (BOOL)isEmptyOrDirectory {
    if (!self.isFileURL) {
        return NO;
    }
    struct stat info;
    if (stat(self.fileSystemRepresentation, &info) != 0) {
        return NO; // unstattable: let the real open report why
    }
    return VibeStatIsEmptyOrDirectory(&info);
}

@end
