//
//  VibeBenchComponentsArt.mm
//  VibeBenchComponents
//
//  The art re-extraction a full-art miss runs: TagLib's open and the picture
//  read.
//

#import "VibeBenchComponents.h"

#if __has_include("AudioTrackArtworkInternal.h")
#import "AudioTrackArtworkInternal.h" // its name before it became the class's only header
#else
#import "AudioTrackArtwork.h"
#endif
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "PlatformImage.h"

#include <memory>

// MARK: - Art

static void VibeBenchComponentsRegisterArt(void) {
    // The art re-extraction a full-art miss runs: TagLib's open and the
    // picture read, twenty per repetition.
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"aac-256"]) {
        auto file = std::make_shared<VibeBenchComponentsFileState>();
        auto extractor = std::make_shared<AudioTrackArtworkExtractor>();
        auto prepare = [name, file, extractor]() -> double {
            file->path = VibeBenchComponentsFile(name);
            if (!file->path) {
                return -1;
            }
            NSData *displayArt = nil;
            AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:[NSURL fileURLWithPath:file->path]
                                                               displayArtData:&displayArt];
            *extractor = [metadata.artwork valueForKey:@"extractor"];
            VibeBenchComponentsRequire(*extractor != nil, "art fixture has no extractor");
            return 20;
        };
        VibeBenchComponentsAdd("art-extract", name.UTF8String, "read", prepare, [file, extractor]() {
            for (int i = 0; i < 20; i++) {
                NSData *art = nil;
                (*extractor)(file->path, &art);
                VibeBenchComponentsRequire(art.length > 0, "art extraction failed");
            }
        });

        for (CGFloat dimension : {128.0, 640.0, 1024.0}) {
            auto bytes = std::make_shared<NSData *>();
            VibeBenchComponentsAdd("art-decode", std::string(name.UTF8String) + "-" + std::to_string((int)dimension),
                                  "image", [file, extractor, bytes, prepare]() -> double {
                if (prepare() < 0) return -1;
                NSData *art = nil;
                (*extractor)(file->path, &art);
                VibeBenchComponentsRequire(art.length > 0, "art decode fixture has no image");
                *bytes = art;
                return 20;
            }, [bytes, dimension]() {
                for (int i = 0; i < 20; i++) {
                    @autoreleasepool {
                        VibeImage *image = VibeDecodedImageWithData(*bytes, dimension);
                        VibeBenchComponentsRequire(image != nil, "art image decode failed");
                    }
                }
            });
        }

        auto image = std::make_shared<VibeImage *>();
        VibeBenchComponentsAdd("art-color", name.UTF8String, "image", [file, extractor, image, prepare]() -> double {
            if (prepare() < 0) return -1;
            NSData *bytes = nil;
            (*extractor)(file->path, &bytes);
            *image = VibeDecodedImageWithData(bytes, 640);
            VibeBenchComponentsRequire(*image != nil, "art color fixture failed");
            return 100;
        }, [image]() {
            for (int i = 0; i < 100; i++) {
                VibeBenchComponentsRequire(VibeDominantColorOfImage(*image) != nil, "dominant color extraction failed");
            }
        });

        for (BOOL hit : {NO, YES}) {
            auto artwork = std::make_shared<AudioTrackArtwork *>();
            auto decode = [artwork]() {
                __block BOOL done = NO;
                BOOL admitted = [*artwork requestEmbeddedThumbnailDecodeWithCompletion:^(VibeImage *thumbnail) {
                    VibeBenchComponentsRequire(thumbnail != nil, "thumbnail delivery failed");
                    done = YES;
                }];
                VibeBenchComponentsRequire(admitted, "thumbnail decode not admitted");
                VibeBenchComponentsSpinMainUntil(^BOOL { return done; });
            };
            VibeBenchComponentsAdd(hit ? "art-thumbnail-hit" : "art-thumbnail-load", name.UTF8String, "image",
                                  [file, extractor, artwork, prepare, decode, hit]() -> double {
                if (prepare() < 0) return -1;
                NSData *bytes = nil;
                (*extractor)(file->path, &bytes);
                *artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:nil extractor:nil];
                [*artwork adoptParsedArtData:bytes];
                if (hit) decode();
                return hit ? 1000 : 20;
            }, [artwork, decode, hit]() {
                for (int i = 0; i < (hit ? 1000 : 20); i++) {
                    if (!hit) {
                        [*artwork evictDecodedThumbnailForTesting];
                        decode();
                    }
                    VibeBenchComponentsRequire([*artwork cachedThumbnail] != nil, "thumbnail cache missed");
                }
            });
        }
    }

}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterArt)
