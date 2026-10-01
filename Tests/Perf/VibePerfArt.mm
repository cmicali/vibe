//
//  VibePerfArt.mm
//  VibePerf
//
//  The art re-extraction a full-art miss runs: TagLib's open and the picture
//  read.
//

#import "VibePerf.h"

#import "AudioTrackArtworkInternal.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"

#include <memory>

// MARK: - Art

static void VibePerfRegisterArt(void) {
    // The art re-extraction a full-art miss runs: TagLib's open and the
    // picture read, twenty per repetition.
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"aac-256"]) {
        auto file = std::make_shared<VibePerfFileState>();
        auto extractor = std::make_shared<AudioTrackArtworkExtractor>();
        VibePerfAdd("art-extract", name.UTF8String, "read", [name, file, extractor]() -> double {
            file->path = VibePerfFile(name);
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

VIBE_PERF_REGISTER(VibePerfRegisterArt)
