//
//  VibeTestServedFile.m
//

#import "VibeTestServedFile.h"

#include <errno.h>

@implementation VibeTestServedFile

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    NSDictionary<NSFileAttributeKey, id> *attributes =
            [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:error];
    if (!attributes) {
        return nil;
    }
    if (attributes.fileSize == 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        }
        return nil;
    }
    return [super init];
}

- (void)holdStream {
}

@end
