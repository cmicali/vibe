//
//  VibeBenchComponentsM3U.mm
//  VibeBenchComponents
//
//  Opening a playlist file: a 10,000-entry M3U resolved.
//

#import "VibeBenchComponents.h"

#import "AudioTrack.h"
#if __has_include("VibePlaylistFile.h")
#import "VibePlaylistFile.h"
#else
#import "PlaylistFile.h"
#define VibePlaylistFile PlaylistFile   // the readers were PlaylistFile before vibe-libs prefixed them
#endif

#include <memory>

// Each version's own path from a playlist file to rows and back. Since the
// readers and the writer take entries, the app makes the rows and entries.
#if __has_include("VibePlaylistEntry.h") || __has_include("PlaylistEntry.h")
static NSArray<AudioTrack *> *VibeBenchPlaylistRows(NSURL *url) {
    return [AudioTrack rowsForEntries:[VibePlaylistFile entriesForPlaylistAtURL:url]];
}
static NSArray<AudioTrack *> *VibeBenchM3URows(NSData *data) {
    return [AudioTrack rowsForEntries:[VibePlaylistFile entriesInM3UData:data]];
}
static NSString *VibeBenchM3UText(NSArray<AudioTrack *> *rows) {
    return [VibePlaylistFile m3uTextForEntries:[AudioTrack entriesForRows:rows] relativeToDirectory:nil];
}
static BOOL VibeBenchWriteM3U(NSArray<AudioTrack *> *rows, NSURL *url) {
    return [VibePlaylistFile writeM3UForEntries:[AudioTrack entriesForRows:rows] relativeToDirectory:nil toURL:url error:nil];
}
#else
static NSArray<AudioTrack *> *VibeBenchPlaylistRows(NSURL *url) {
    return [VibePlaylistFile rowsForPlaylistAtURL:url];
}
static NSArray<AudioTrack *> *VibeBenchM3URows(NSData *data) {
    return [VibePlaylistFile rowsInM3UData:data];
}
static NSString *VibeBenchM3UText(NSArray<AudioTrack *> *rows) {
    return [VibePlaylistFile m3uTextForTracks:rows relativeToDirectory:nil];
}
static BOOL VibeBenchWriteM3U(NSArray<AudioTrack *> *rows, NSURL *url) {
    return [VibePlaylistFile writeM3UForTracks:rows relativeToDirectory:nil toURL:url error:nil];
}
#endif

static void VibeBenchComponentsRegisterM3U(void) {
    // A 10,000-entry M3U of relative paths, every file present.
    auto m3u = std::make_shared<NSURL *>();
    auto prepare = [m3u]() -> double {
        if (*m3u) return 10000;
        NSString *root = VibeBenchComponentsTemporaryDirectory(@"m3u");
        NSArray<NSString *> *files = VibeBenchComponentsMakeFiles(root, 10000, @"mp3");
        NSString *text = [[@"#EXTM3U\n" stringByAppendingString:[files componentsJoinedByString:@"\n"]]
                stringByAppendingString:@"\n"];
        NSString *path = [root stringByAppendingPathComponent:@"list.m3u8"];
        VibeBenchComponentsRequire([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],
                                   "M3U fixture write failed");
        *m3u = [NSURL fileURLWithPath:path];
        return 10000;
    };
    VibeBenchComponentsAdd("m3u", "resolve-10k", "entry", prepare, [m3u]() {
        NSArray<AudioTrack *> *rows = VibeBenchPlaylistRows(*m3u);
        VibeBenchComponentsRequire(rows.count == 10000, "M3U resolved the wrong row count");
    });

    for (BOOL write : {NO, YES}) {
        auto rows = std::make_shared<NSArray<AudioTrack *> *>();
        auto bytes = std::make_shared<NSData *>();
        VibeBenchComponentsAdd("m3u", write ? "write-10k" : "restore-10k", "entry",
                              [prepare, m3u, rows, bytes]() -> double {
            prepare();
            *rows = VibeBenchPlaylistRows(*m3u);
            VibeBenchComponentsRequire((*rows).count == 10000, "M3U write fixture lost rows");
            *bytes = [VibeBenchM3UText(*rows) dataUsingEncoding:NSUTF8StringEncoding];
            return 10000;
        }, [rows, bytes, m3u, write]() {
            if (write) {
                NSURL *out = [[*m3u URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"saved.m3u8"];
                VibeBenchComponentsRequire(VibeBenchWriteM3U(*rows, out), "M3U write failed");
            } else {
                VibeBenchComponentsRequire(VibeBenchM3URows(*bytes).count == 10000, "M3U restore lost rows");
            }
        });
    }

    auto cue = std::make_shared<NSURL *>();
    VibeBenchComponentsAdd("cue", "resolve-90", "row", [cue]() -> double {
        NSString *audio = VibeBenchComponentsFile(@"flac-16-44");
        if (!audio) return -1;
        NSMutableString *text = [NSMutableString stringWithFormat:@"FILE \"%@\" WAVE\n", audio];
        for (NSUInteger i = 0; i < 90; i++) {
            [text appendFormat:@"  TRACK %02lu AUDIO\n    TITLE \"Track %lu\"\n    INDEX 01 %02lu:%02lu:00\n",
                               (unsigned long)i + 1, (unsigned long)i, (unsigned long)(i * 2 / 60), (unsigned long)(i * 2 % 60)];
        }
        *cue = [NSURL fileURLWithPath:[VibeBenchComponentsTemporaryDirectory(@"cue") stringByAppendingPathComponent:@"mix.cue"]];
        VibeBenchComponentsRequire([text writeToURL:*cue atomically:YES encoding:NSUTF8StringEncoding error:nil],
                                   "CUE fixture write failed");
        return 90 * 20;
    }, [cue]() {
        for (int i = 0; i < 20; i++) {
            VibeBenchComponentsRequire(VibeBenchPlaylistRows(*cue).count == 90, "CUE parse lost rows");
        }
    });
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterM3U)
