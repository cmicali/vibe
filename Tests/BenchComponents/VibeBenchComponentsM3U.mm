//
//  VibeBenchComponentsM3U.mm
//  VibeBenchComponents
//
//  Opening a playlist file: a 10,000-entry M3U resolved.
//

#import "VibeBenchComponents.h"

#import "AudioTrack.h"
#import "PlaylistFile.h"

#include <memory>

static void VibeBenchComponentsRegisterM3U(void) {
    // A 10,000-entry M3U of relative paths, every file present.
    auto m3u = std::make_shared<NSURL *>();
    VibeBenchComponentsAdd("m3u", "resolve-10k", "entry", [m3u]() -> double {
        NSString *root = VibeBenchComponentsTemporaryDirectory(@"m3u");
        NSArray<NSString *> *files = VibeBenchComponentsMakeFiles(root, 10000, @"mp3");
        NSString *text = [[@"#EXTM3U\n" stringByAppendingString:[files componentsJoinedByString:@"\n"]]
                stringByAppendingString:@"\n"];
        NSString *path = [root stringByAppendingPathComponent:@"list.m3u8"];
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        *m3u = [NSURL fileURLWithPath:path];
        return 10000;
    }, [m3u]() {
        NSArray<AudioTrack *> *rows = [PlaylistFile rowsForPlaylistAtURL:*m3u];
        if (rows.count != 10000) {
            printf("warning: m3u resolved %lu rows\n", (unsigned long)rows.count);
        }
    });
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterM3U)
