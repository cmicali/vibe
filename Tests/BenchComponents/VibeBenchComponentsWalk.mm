//
//  VibeBenchComponentsWalk.mm
//  VibeBenchComponents
//
//  Opening a dropped folder: the walk, the filter and the sort.
//

#import "VibeBenchComponents.h"

#import "AudioTrack.h"
#import "NSURLUtilInternal.h"

#include <memory>

static void VibeBenchComponentsRegisterWalk(void) {
    // A dropped folder of 10,000 files, walked, filtered and sorted.
    auto folder = std::make_shared<NSURL *>();
    auto prepareFolder = [folder]() -> double {
        if (!*folder) {
            NSString *root = VibeBenchComponentsTemporaryDirectory(@"walk");
            VibeBenchComponentsMakeFiles(root, 10000, @"flac");
            *folder = [NSURL fileURLWithPath:root isDirectory:YES];
        }
        return 10000;
    };
    for (auto sort : {VibeFolderOpenSortName, VibeFolderOpenSortNewestFirst}) {
        VibeBenchComponentsAdd("walk", sort == VibeFolderOpenSortName ? "10k-name" : "10k-newest", "file", prepareFolder,
                    [folder, sort]() {
            NSUInteger folders = 0;
            NSArray<AudioTrack *> *rows = [NSURLUtil expandAndFilterList:@[*folder] sortedBy:sort folderCount:&folders];
            if (rows.count != 10000) {
                printf("warning: walk found %lu rows\n", (unsigned long)rows.count);
            }
        });
    }

    // The corpus library: 600 real files with covers beside them.
    VibeBenchComponentsAdd("walk", "library", "file", []() -> double {
        return [NSFileManager.defaultManager fileExistsAtPath:[VibeBenchComponentsCorpus() stringByAppendingPathComponent:@"library"]]
                ? 600 : -1;
    }, []() {
        NSUInteger folders = 0;
        NSURL *library = [NSURL fileURLWithPath:[VibeBenchComponentsCorpus() stringByAppendingPathComponent:@"library"] isDirectory:YES];
        (void)[NSURLUtil expandAndFilterList:@[library] sortedBy:VibeFolderOpenSortName folderCount:&folders];
    });
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterWalk)
