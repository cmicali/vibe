//
//  VibeBenchComponentsArt.mm
//  VibeBenchComponents
//
//  The art re-extraction a full-art miss runs: TagLib's open and the picture
//  read.
//

#import "VibeBenchComponents.h"

#import "AudioTrackArtworkInternal.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"

#include <memory>

// MARK: - Art

static void VibeBenchComponentsRegisterArt(void) {
    // The art re-extraction a full-art miss runs: TagLib's open and the
    // picture read, twenty per repetition.
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"aac-256"]) {
        auto file = std::make_shared<VibeBenchComponentsFileState>();
        auto extractor = std::make_shared<AudioTrackArtworkExtractor>();
        VibeBenchComponentsAdd("art-extract", name.UTF8String, "read", [name, file, extractor]() -> double {
            file->path = VibeBenchComponentsFile(name);
            if (!file->path) {
                return -1;
            }
            NSData *displayArt = nil;
            AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:[NSURL fileURLWithPath:file->path]
                                                               displayArtData:&displayArt];
            *extractor = [metadata.artwork valueForKey:@"extractor"];
            return *extractor ? 20 : -1;
        }, [file, extractor]() {
            for (int i = 0; i < 20; i++) {
                NSData *art = nil;
                (*extractor)(file->path, &art);
            }
        });
    }

}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterArt)
