//
//  VibeBenchComponentsWalk.mm
//  VibeBenchComponents
//
//  Opening a dropped folder: the walk, the filter, the sort and the rows.
//

#import "VibeBenchComponents.h"

#import "AudioTrack.h"
#if __has_include("FolderWalkInternal.h")
#import "FolderWalkInternal.h"
#else
#import "NSURLUtilInternal.h"
#define FolderWalk NSURLUtil   // the walk was NSURLUtil before it moved to Playlist/
#endif

#if __has_include("PlaylistEntry.h")
// The walk answers entries, and the app makes its rows from them.
#define VibeBenchWalkRows(entries) [AudioTrack rowsForEntries:(entries)]
#else
#define VibeBenchWalkRows(rows) (rows)
#endif

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
            NSArray<AudioTrack *> *rows =
                    VibeBenchWalkRows([FolderWalk expandAndFilterList:@[*folder] sortedBy:sort folderCount:&folders]);
            VibeBenchComponentsRequire(rows.count == 10000, "folder walk lost rows");
        });
    }

    // The corpus library: 600 real files with covers beside them.
    VibeBenchComponentsAdd("walk", "library", "file", []() -> double {
        return [NSFileManager.defaultManager fileExistsAtPath:[VibeBenchComponentsCorpus() stringByAppendingPathComponent:@"library"]]
                ? 600 : -1;
    }, []() {
        NSUInteger folders = 0;
        NSURL *library = [NSURL fileURLWithPath:[VibeBenchComponentsCorpus() stringByAppendingPathComponent:@"library"] isDirectory:YES];
        NSArray<AudioTrack *> *rows = VibeBenchWalkRows(
                [FolderWalk expandAndFilterList:@[library] sortedBy:VibeFolderOpenSortName folderCount:&folders]);
        VibeBenchComponentsRequire(rows.count == 600, "library walk lost rows");
    });
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterWalk)
