//
//  VibeBenchComponentsMetadata.mm
//  VibeBenchComponents
//
//  The metadata scan's parse of one file, and the cache key every lookup
//  derives.
//

#import "VibeBenchComponents.h"

#import "AudioTrackMetadata.h"
#if __has_include("AudioTrackMetadataInternal.h")
#import "AudioTrackMetadataInternal.h"
#endif
#import "NSURL+Hash.h"

// The metadata scan's parse of one file: TagLib, the facts, the thumbnail and,
// where the version makes one, the display-art rendition.
static void VibeBenchComponentsParse(NSURL *url) {
#if VIBE_BENCH_COMPONENTS_METADATA_DISPLAY_ART
    NSData *displayArt = nil;
    (void)[AudioTrackMetadata metadataWithURL:url displayArtData:&displayArt];
#else
    (void)[AudioTrackMetadata metadataWithURL:url];
#endif
}

// The corpus library's files, every one or one extension's.
static void VibeBenchComponentsLibraryURLs(NSString *extension, std::vector<NSURL *> &urls) {
    NSString *root = [VibeBenchComponentsCorpus() stringByAppendingPathComponent:@"library"];
    for (NSString *relative in [NSFileManager.defaultManager enumeratorAtPath:root]) {
        if (![relative.lastPathComponent hasPrefix:@"."] && relative.pathExtension.length
                && (!extension || [relative.pathExtension isEqualToString:extension])) {
            urls.push_back([NSURL fileURLWithPath:[root stringByAppendingPathComponent:relative]]);
        }
    }
}

static void VibeBenchComponentsRegisterMetadata(void) {
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"aac-256", @"wav-24-96"]) {
        auto file = std::make_shared<VibeBenchComponentsFileState>();
        // Ten per repetition.
        VibeBenchComponentsAdd("metadata", name.UTF8String, "parse", [name, file]() -> double {
            file->path = VibeBenchComponentsFile(name);
            return file->path ? 10 : -1;
        }, [file]() {
            NSURL *url = [NSURL fileURLWithPath:file->path];
            for (int i = 0; i < 10; i++) {
                VibeBenchComponentsParse(url);
            }
        });
    }
    // The scan's parse over the library's MP3s, which carry ID3v2 tags and a
    // cover each.
    auto library = std::make_shared<std::vector<NSURL *>>();
    VibeBenchComponentsAdd("metadata", "library-mp3", "parse", [library]() -> double {
        VibeBenchComponentsLibraryURLs(@"mp3", *library);
        return library->empty() ? -1 : (double)library->size();
    }, [library]() {
        for (NSURL *url : *library) {
            VibeBenchComponentsParse(url);
        }
    });

    // The cache key every lookup derives, over the 600-file library.
    auto urls = std::make_shared<std::vector<NSURL *>>();
    VibeBenchComponentsAdd("cachekey", "library", "key", [urls]() -> double {
        VibeBenchComponentsLibraryURLs(nil, *urls);
        return urls->empty() ? -1 : (double)urls->size();
    }, [urls]() {
        for (NSURL *url : *urls) {
            (void)url.cacheKey;
        }
    });
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterMetadata)
