//
//  VibeBenchComponentsDecode.mm
//  VibeBenchComponents
//
//  Opening, decoding and seeking through the player's file reader in the
//  version measured: AudioFileHandle from 1.14, AVAudioFile before.
//

#import "VibeBenchComponents.h"
#if VIBE_BENCH_COMPONENTS_FILE_HANDLE
#import "AudioFileHandle.h"
#endif


// MARK: - Benchmarks: file reading, opening, decode

static void VibeBenchComponentsRegisterDecode(void) {
    NSArray<NSString *> *files = @[@"mp3-320", @"mp3-v0", @"aac-256", @"flac-16-44", @"flac-24-96", @"flac-24-192",
                                   @"wav-24-96", @"wav-16-44", @"aiff-16-44", @"alac-16-44", @"opus", @"vorbis",
                                   @"flac-16-22-mono", @"mp3-320-48k", @"mp3-320-60min", @"mp3-v0-60min",
                                   @"mp3-v0-noxing", @"flac-24-88", @"flac-24-176", @"flac-24-352", @"caf-16-44",
                                   @"w64-16-44", @"rf64-16-44", @"wav-f32-44", @"wav-5.1-44", @"aac-adts", @"mp2-320"];
    for (NSString *name in files) {
        for (int apple = 0; apple <= (VIBE_BENCH_COMPONENTS_APPLE_MPEG && [name hasPrefix:@"mp"]); apple++) {
            std::string n = std::string(name.UTF8String) + (apple ? "-apple" : "");
            auto file = std::make_shared<VibeBenchComponentsFileState>();
            auto openReader = [file, apple](BOOL interleaved) {
#if VIBE_BENCH_COMPONENTS_APPLE_MPEG
                BOOL previous = AudioFileHandle.appleMPEGDecoder;
                AudioFileHandle.appleMPEGDecoder = apple;
#endif
                VibeBenchComponentsReader *reader = [[VibeBenchComponentsReader alloc] initWithPath:file->path
                                                                                                      interleaved:interleaved];
#if VIBE_BENCH_COMPONENTS_APPLE_MPEG
                AudioFileHandle.appleMPEGDecoder = previous;
#endif
                VibeBenchComponentsRequire(reader != nil, "audio open failed");
                return reader;
            };
            auto seconds = [name, file, openReader]() -> double {
                file->path = VibeBenchComponentsFile(name);
                if (!file->path) return -1;
                VibeBenchComponentsReader *reader = openReader(NO);
                return (double)reader.length / reader.processingFormat.sampleRate;
            };
            auto twenty = [seconds]() -> double { return seconds() > 0 ? 20 : -1; };
            auto fifty = [seconds]() -> double { return seconds() > 0 ? 50 : -1; };

            // What the player's open of a file costs: the parser, the codec or
            // the dr_* decoder, and the close. Twenty per repetition.
            VibeBenchComponentsAdd("open", n, "open", twenty, [openReader]() {
                for (int i = 0; i < 20; i++) {
                    VibeBenchComponentsReader *reader = openReader(NO);
                    (void)reader;
                }
            });

            // A new track's first playable block, including open and close.
            VibeBenchComponentsAdd("load", n, "load", twenty, [openReader]() {
                for (int i = 0; i < 20; i++) {
                    VibeBenchComponentsReader *reader = openReader(NO);
                    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat
                                                                           frameCapacity:4096];
                    VibeBenchComponentsRequire([reader read:buffer], "first read produced no frames");
                }
            });

            // Playback reads planar 4096-frame slices. The waveform loader reads
            // interleaved 65536-frame blocks through the same file handle.
            for (BOOL interleaved : {NO, YES}) {
                VibeBenchComponentsAdd(interleaved ? "decode-il" : "decode", n, "audio s", seconds,
                                      [openReader, interleaved]() {
                    VibeBenchComponentsReader *reader = openReader(interleaved);
                    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat
                                                                           frameCapacity:interleaved ? 65536 : 4096];
                    uint64_t frames = 0;
                    while ([reader read:buffer]) frames += buffer.frameLength;
                    // Parser lengths can differ by codec priming or a final packet.
                    VibeBenchComponentsRequire(frames > 0 && llabs((long long)frames - reader.length) <= 8192,
                                               "decode stopped before the file's end");
                });
            }

            if ([name isEqualToString:@"mp3-320"] || [name isEqualToString:@"flac-16-44"] ||
                    [name isEqualToString:@"aac-256"] || [name isEqualToString:@"vorbis"]) {
                VibeBenchComponentsAdd("decode-window", n, "audio s", [seconds]() -> double {
                    return seconds() >= 90 ? 30 : -1;
                }, [openReader]() {
                    VibeBenchComponentsReader *reader = openReader(NO);
                    [reader seekTo:(long long)(60 * reader.processingFormat.sampleRate)];
                    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat
                                                                           frameCapacity:4096];
                    uint64_t remaining = (uint64_t)(30 * reader.processingFormat.sampleRate);
                    while (remaining) {
                        [reader read:buffer frames:(AVAudioFrameCount)MIN(remaining, buffer.frameCapacity)];
                        VibeBenchComponentsRequire(buffer.frameLength > 0 && buffer.frameLength <= remaining,
                                                   "window decode ended early");
                        remaining -= buffer.frameLength;
                    }
                });
            }

            // A seek and the first turn after it, as a skip or a scrub does: fifty
            // seeded positions over the whole file.
            for (const char *operation : {"seek", "skip-forward", "skip-backward"}) {
                std::string op = operation;
                VibeBenchComponentsAdd(op, n, "seek", fifty, [openReader, op]() {
                    VibeBenchComponentsReader *reader = openReader(NO);
                    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat frameCapacity:4096];
                    uint64_t state = 0x9E3779B97F4A7C15ull;
                    for (int i = 0; i < 50; i++) {
                        state = state * 6364136223846793005ull + 1442695040888963407ull;
                        uint64_t available = (uint64_t)MAX(1, reader.length - 8192);
                        long long target = (long long)((state >> 33) % available);
                        if (op != "seek") {
                            uint64_t step = (uint64_t)(5 * reader.processingFormat.sampleRate);
                            uint64_t offset = ((i + 1) * step) % available;
                            target = (long long)(op == "skip-forward" ? offset : available - 1 - offset);
                        }
                        [reader seekTo:target];
                        VibeBenchComponentsRequire([reader read:buffer], "seek produced no frames");
                    }
                });
            }
        }
    }

#if VIBE_BENCH_COMPONENTS_FILE_HANDLE
    for (NSString *name in @[@"flac-16-44", @"flac-24-96"]) {
        auto buffer = std::make_shared<AVAudioPCMBuffer *>();
        auto file = std::make_shared<VibeBenchComponentsFileState>();
        VibeBenchComponentsAdd("encode-flac", name.UTF8String, "audio s", [name, buffer, file]() -> double {
            NSString *path = VibeBenchComponentsFile(name);
            if (!path) return -1;
            VibeBenchComponentsReader *reader = [[VibeBenchComponentsReader alloc] initWithPath:path interleaved:NO];
            VibeBenchComponentsRequire(reader != nil, "encode source open failed");
            *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat
                                                  frameCapacity:(AVAudioFrameCount)(reader.processingFormat.sampleRate * 10)];
            VibeBenchComponentsRequire([reader read:*buffer] && (*buffer).frameLength == (*buffer).frameCapacity,
                                       "encode source read was short");
            file->path = [VibeBenchComponentsTemporaryDirectory(@"encode") stringByAppendingPathComponent:@"output.flac"];
            return 10;
        }, [name, buffer, file]() {
            AudioStreamBasicDescription flac = {};
            flac.mFormatID = kAudioFormatFLAC;
            flac.mSampleRate = (*buffer).format.sampleRate;
            flac.mChannelsPerFrame = (*buffer).format.channelCount;
            flac.mFormatFlags = [name isEqualToString:@"flac-16-44"] ? kAppleLosslessFormatFlag_16BitSourceData
                                                                  : kAppleLosslessFormatFlag_24BitSourceData;
            AudioFileHandle *writer = [[AudioFileHandle alloc] initForWriting:[NSURL fileURLWithPath:file->path]
                    fileType:kAudioFileFLACType fileFormat:[[AVAudioFormat alloc] initWithStreamDescription:&flac]
                    processingFormat:(*buffer).format error:nil];
            VibeBenchComponentsRequire(writer != nil && [writer writeFromBuffer:*buffer error:nil] &&
                                       [writer closeWithError:nil], "FLAC encode or close failed");
        });
    }
#endif
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterDecode)
