//
//  NSURL+AudioOpen.h
//  Vibe
//

#import <Foundation/Foundation.h>
#include <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

// TRAP: st_size, never st_blocks or NSURLFileAllocatedSizeKey: a dataless
// cloud file has its true size but zero allocated blocks, so an allocation
// test would reject every cloud track.
static inline BOOL VibeStatIsEmptyOrDirectory(const struct stat *info) {
    return S_ISDIR(info->st_mode) || info->st_size == 0;
}

@interface NSURL (AudioOpen)

// A zero-length file or a directory. One stat, no open; NO when the stat
// fails, so the real open reports why.
@property (nonatomic, readonly) BOOL isEmptyOrDirectory;

@end

NS_ASSUME_NONNULL_END
