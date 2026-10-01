//
//  VibeBenchComponentsDecode.mm
//  VibeBenchComponents
//
//  Opening, decoding and seeking through the player's file reader in the
//  version measured: AudioFileHandle from 1.14, AVAudioFile before.
//

#import "VibeBenchComponents.h"


// MARK: - Benchmarks: file reading, opening, decode

static void VibeBenchComponentsRegisterDecode(void) {
    NSArray<NSString *> *files = @[@"mp3-320", @"mp3-v0", @"aac-256", @"flac-16-44", @"flac-24-96", @"flac-24-192",
                                   @"wav-24-96", @"wav-16-44", @"aiff-16-44", @"alac-16-44", @"opus", @"vorbis",
                                   @"flac-16-22-mono"];
    for (NSString *name in files) {
        std::string n = name.UTF8String;
        auto file = std::make_shared<VibeBenchComponentsFileState>();
        auto seconds = [name, file]() -> double {
            file->path = VibeBenchComponentsFile(name);
            return VibeBenchComponentsAudioSeconds(file->path);
        };
        auto twenty = [seconds]() -> double { return seconds() > 0 ? 20 : -1; };
        auto fifty = [seconds]() -> double { return seconds() > 0 ? 50 : -1; };

        // What the player's open of a file costs: the parser, the codec or
        // the dr_* decoder, and the close. Twenty per repetition.
        VibeBenchComponentsAdd("open", n, "open", twenty, [file]() {
            for (int i = 0; i < 20; i++) {
                VibeBenchComponentsReader *reader = [[VibeBenchComponentsReader alloc] initWithPath:file->path interleaved:NO];
                (void)reader;
            }
        });

        // The voice bus's read: planar float32 in 4096-frame turns.
        VibeBenchComponentsAdd("decode", n, "audio s", seconds, [file]() {
            VibeBenchComponentsReader *reader = [[VibeBenchComponentsReader alloc] initWithPath:file->path interleaved:NO];
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat frameCapacity:4096];
            while ([reader read:buffer]) {
            }
        });

        // The waveform loader's read: interleaved float32 in 65536-frame blocks.
        VibeBenchComponentsAdd("decode-il", n, "audio s", seconds, [file]() {
            VibeBenchComponentsReader *reader = [[VibeBenchComponentsReader alloc] initWithPath:file->path interleaved:YES];
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat frameCapacity:65536];
            while ([reader read:buffer]) {
            }
        });

        // A seek and the first turn after it, as a skip or a scrub does: fifty
        // seeded positions over the whole file.
        VibeBenchComponentsAdd("seek", n, "seek", fifty, [file]() {
            VibeBenchComponentsReader *reader = [[VibeBenchComponentsReader alloc] initWithPath:file->path interleaved:NO];
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat frameCapacity:4096];
            uint64_t state = 0x9E3779B97F4A7C15ull;
            for (int i = 0; i < 50; i++) {
                state = state * 6364136223846793005ull + 1442695040888963407ull;
                long long target = (long long)((state >> 33) % (uint64_t)MAX(1, reader.length - 8192));
                [reader seekTo:target];
                [reader read:buffer];
            }
        });
    }
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterDecode)
