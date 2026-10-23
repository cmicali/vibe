//
//  LegacyCacheStores.m
//  Vibe
//

#import "LegacyCacheStores.h"
#import "PINDiskCache.h"

// The name without its version suffix.
static NSString *StoreFamily(NSString *name) {
    NSRange suffix = [name rangeOfString:@"[ _]v[0-9]+$" options:NSRegularExpressionSearch];
    return suffix.location == NSNotFound ? name : [name substringToIndex:suffix.location];
}

void VibeRemoveLegacyCacheStores(NSString *cachesDirectory, NSArray<NSString *> *currentStoreNames) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    // PINDiskCache names each store's directory "<prefix>.<name>".
    NSString *prefix = [PINDiskCachePrefix stringByAppendingString:@"."];
    for (NSString *entry in [fileManager contentsOfDirectoryAtPath:cachesDirectory error:nil]) {
        if (![entry hasPrefix:prefix]) {
            continue;
        }
        NSString *name = [entry substringFromIndex:prefix.length];
        for (NSString *current in currentStoreNames) {
            if (![name isEqualToString:current] && [StoreFamily(name) isEqualToString:StoreFamily(current)]) {
                [fileManager removeItemAtPath:[cachesDirectory stringByAppendingPathComponent:entry] error:nil];
                break;
            }
        }
    }
}
