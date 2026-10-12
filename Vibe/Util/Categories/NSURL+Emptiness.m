//
//  NSURL+Emptiness.m
//  Vibe
//

#import "NSURL+Emptiness.h"

@implementation NSURL (Emptiness)

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
