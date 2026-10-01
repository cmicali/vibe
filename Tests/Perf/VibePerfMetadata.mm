//
//  VibePerfMetadata.mm
//  VibePerf
//
//  The metadata scan's parse of one file, and the cache key every lookup
//  derives.
//

#import "VibePerf.h"

#import "AudioTrackMetadata.h"
#if __has_include("AudioTrackMetadataInternal.h")
#import "AudioTrackMetadataInternal.h"
#endif
#import "NSURL+Hash.h"

static void VibePerfRegisterMetadata(void) {
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"aac-256", @"wav-24-96"]) {
        auto file = std::make_shared<VibePerfFileState>();
        // The metadata scan's parse of one file: TagLib, the facts, the
        // thumbnail and the display-art rendition. Ten per repetition.
        VibePerfAdd("metadata", name.UTF8String, "parse", [name, file]() -> double {
            file->path = VibePerfFile(name);
            return file->path ? 10 : -1;
        }, [file]() {
            NSURL *url = [NSURL fileURLWithPath:file->path];
            for (int i = 0; i < 10; i++) {
#if VIBE_PERF_METADATA_DISPLAY_ART
                NSData *displayArt = nil;
                AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:url displayArtData:&displayArt];
#else
                AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:url];
#endif
                (void)metadata;
            }
        });
    }
    // The scan's parse over the library's MP3s, which carry ID3v2 tags and a
    // cover each.
    auto library = std::make_shared<std::vector<NSURL *>>();
    VibePerfAdd("metadata", "library-mp3", "parse", [library]() -> double {
        NSString *root = [VibePerfCorpus() stringByAppendingPathComponent:@"library"];
        for (NSString *relative in [NSFileManager.defaultManager enumeratorAtPath:root]) {
            if ([relative.pathExtension isEqualToString:@"mp3"] && ![relative.lastPathComponent hasPrefix:@"."]) {
                library->push_back([NSURL fileURLWithPath:[root stringByAppendingPathComponent:relative]]);
            }
        }
        return library->empty() ? -1 : (double)library->size();
    }, [library]() {
        for (NSURL *url : *library) {
#if VIBE_PERF_METADATA_DISPLAY_ART
            NSData *displayArt = nil;
            (void)[AudioTrackMetadata metadataWithURL:url displayArtData:&displayArt];
#else
            (void)[AudioTrackMetadata metadataWithURL:url];
#endif
        }
    });

    // The cache key every lookup derives, over the 600-file library.
    auto urls = std::make_shared<std::vector<NSURL *>>();
    VibePerfAdd("cachekey", "library", "key", [urls]() -> double {
        NSString *library = [VibePerfCorpus() stringByAppendingPathComponent:@"library"];
        for (NSString *relative in [NSFileManager.defaultManager enumeratorAtPath:library]) {
            if (![relative.lastPathComponent hasPrefix:@"."] && relative.pathExtension.length) {
                urls->push_back([NSURL fileURLWithPath:[library stringByAppendingPathComponent:relative]]);
            }
        }
        return urls->empty() ? -1 : (double)urls->size();
    }, [urls]() {
        for (NSURL *url : *urls) {
            (void)url.cacheKey;
        }
    });
}

VIBE_PERF_REGISTER(VibePerfRegisterMetadata)
