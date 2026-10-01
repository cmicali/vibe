//
//  VibePerfAudio.mm
//  VibePerf
//
//  File reading, opening, decode, seeks, resampling, the waveform pass, the
//  tempo and key analyzers, the equalizer's analyzer, and the metadata parse.
//

#import "VibePerf.h"

#import <AVFAudio/AVFAudio.h>
#import <Accelerate/Accelerate.h>

#import "AudioFileHandle.h"
#import "AudioResampler.h"
#import "AudioWaveform.h"
#import "AudioWaveformLoader.h"
#import "AudioBPMAnalyzer.h"
#import "AudioKeyAnalyzer.h"
extern "C" {
#import "AudioLevelAnalyzer.h"
}
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "NSURL+Hash.h"

#include <algorithm>

// MARK: - Benchmarks: file reading, opening, decode

static void VibePerfRegisterDecode(void) {
    NSArray<NSString *> *files = @[@"mp3-320", @"mp3-v0", @"aac-256", @"flac-16-44", @"flac-24-96", @"flac-24-192",
                                   @"wav-24-96", @"wav-16-44", @"aiff-16-44", @"alac-16-44", @"opus", @"vorbis",
                                   @"flac-16-22-mono"];
    for (NSString *name in files) {
        std::string n = name.UTF8String;
        auto file = std::make_shared<VibePerfFileState>();
        auto seconds = [name, file]() -> double {
            file->path = VibePerfFile(name);
            return VibePerfAudioSeconds(file->path);
        };
        auto twenty = [seconds]() -> double { return seconds() > 0 ? 20 : -1; };
        auto fifty = [seconds]() -> double { return seconds() > 0 ? 50 : -1; };

        // What the player's handle open costs: the parser, the codec or the
        // dr_* decoder, and the close. Twenty per repetition.
        VibePerfAdd("open", n, "open", twenty, [file]() {
            NSURL *url = [NSURL fileURLWithPath:file->path];
            for (int i = 0; i < 20; i++) {
                AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url error:nil];
                (void)handle;
            }
        });

        // The voice bus's read: planar float32 in 4096-frame turns.
        VibePerfAdd("decode", n, "audio s", seconds, [file]() {
            AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:[NSURL fileURLWithPath:file->path] error:nil];
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:4096];
            while ([handle readIntoBuffer:buffer error:nil] && buffer.frameLength > 0) {
            }
        });

        // The waveform loader's read: interleaved float32 in 65536-frame blocks.
        VibePerfAdd("decode-il", n, "audio s", seconds, [file]() {
            AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:[NSURL fileURLWithPath:file->path]
                                                                  interleaved:YES
                                                                        error:nil];
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:65536];
            while ([handle readIntoBuffer:buffer error:nil] && buffer.frameLength > 0) {
            }
        });

        // A seek and the first turn after it, as a skip or a scrub does: fifty
        // seeded positions over the whole file.
        VibePerfAdd("seek", n, "seek", fifty, [file]() {
            AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:[NSURL fileURLWithPath:file->path] error:nil];
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:4096];
            uint64_t state = 0x9E3779B97F4A7C15ull;
            for (int i = 0; i < 50; i++) {
                state = state * 6364136223846793005ull + 1442695040888963407ull;
                AVAudioFramePosition target = (AVAudioFramePosition)((state >> 33) % (uint64_t)MAX(1, handle.length - 8192));
                [handle seekToFrame:target error:nil];
                [handle readIntoBuffer:buffer error:nil];
            }
        });
    }
}

// MARK: - Benchmarks: resampling

struct VibePerfConverterSource {
    const float *left;
    const float *right;
    NSUInteger frames;
    NSUInteger cursor;
};

static uint32_t VibePerfConverterInput(void *userData, uint32_t maxFrames, const float **channels) {
    VibePerfConverterSource *source = (VibePerfConverterSource *)userData;
    if (source->cursor >= source->frames) {
        return 0;
    }
    uint32_t frames = (uint32_t)MIN((NSUInteger)maxFrames, source->frames - source->cursor);
    channels[0] = source->left + source->cursor;
    channels[1] = source->right + source->cursor;
    source->cursor += frames;
    return frames;
}

static void VibePerfRegisterResample(void) {
    // From the rates the corpus plays to the 48 kHz built-in output, the way
    // the bus's decoder fills: 4096 output frames a turn, over 30 s of noise.
    for (double rate : {44100.0, 88200.0, 96000.0, 176400.0, 192000.0}) {
        auto noise = std::make_shared<std::vector<float>>();
        const double seconds = 30;
        VibePerfAdd("resample", std::to_string((int)rate), "audio s", [noise, rate, seconds]() -> double {
            noise->resize((size_t)(rate * seconds) * 2);
            uint32_t state = 22222;
            for (float &sample : *noise) {
                state = state * 1664525u + 1013904223u;
                sample = (float)(int32_t)state / 2147483648.0f * 0.5f;
            }
            return seconds;
        }, [noise, rate]() {
            size_t frames = noise->size() / 2;
            VibeConverter *converter = VibeConverterCreate(rate, 48000, 2);
            VibePerfConverterSource source = {noise->data(), noise->data() + frames, frames, 0};
            std::vector<float> outLeft(4096), outRight(4096);
            float *out[2] = {outLeft.data(), outRight.data()};
            while (VibeConverterFill(converter, VibePerfConverterInput, &source, 4096, out) > 0) {
            }
            VibeConverterDispose(converter);
        });
    }
}

// MARK: - Benchmarks: the waveform pass and analysis

static void VibePerfRegisterWaveform(void) {
    // The whole cold waveform pass, as the cache runs it: open, pipelined
    // decode, downmix, chunks, with and without both analyzers riding along.
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"flac-24-192", @"aac-256", @"wav-24-96"]) {
        for (int analysis = 0; analysis < 2; analysis++) {
            auto file = std::make_shared<VibePerfFileState>();
            VibePerfAdd(analysis ? "waveform+bpm+key" : "waveform", name.UTF8String, "audio s", [name, file]() -> double {
                file->path = VibePerfFile(name);
                return VibePerfAudioSeconds(file->path);
            }, [file, analysis]() {
                AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] init];
                if (analysis) {
                    loader.analysisProvider = ^VibeWaveformAnalysis {
                        return (VibeWaveformAnalysis){YES, YES};
                    };
                }
                CodableAudioWaveform *result = [loader load:file->path];
                (void)result;
            });
        }
    }

    // The analyzers alone, on PCM decoded once: the streaming append at the
    // loader's block size, then the end-of-file estimate.
    for (NSString *name in @[@"flac-16-44", @"flac-24-96"]) {
        std::string n = name.UTF8String;
        VibePerfAdd("bpm", n, "audio s", VibePerfPCMPrepare(name), [name]() {
            VibePerfPCM *pcm = VibePerfDecoded(name);
            AudioBPMAnalyzer *analyzer = [[AudioBPMAnalyzer alloc] initWithSampleRate:pcm->rate];
            for (NSUInteger at = 0; at < pcm->frames; at += 65536) {
                [analyzer appendMonoSamples:pcm->mono.data() + at frameCount:MIN((NSUInteger)65536, pcm->frames - at)];
            }
            [analyzer finish];
        });
        VibePerfAdd("key", n, "audio s", VibePerfPCMPrepare(name), [name]() {
            VibePerfPCM *pcm = VibePerfDecoded(name);
            AudioKeyAnalyzer *analyzer = [[AudioKeyAnalyzer alloc] initWithSampleRate:pcm->rate];
            for (NSUInteger at = 0; at < pcm->frames; at += 65536) {
                [analyzer appendMonoSamples:pcm->mono.data() + at frameCount:MIN((NSUInteger)65536, pcm->frames - at)];
            }
            [analyzer finish];
        });
        // The loader's processing side without the analyzers: the downmix
        // and the chunk merge over the waveform's chunks.
        VibePerfAdd("chunker", n, "audio s", VibePerfPCMPrepare(name), [name]() {
            VibePerfPCM *pcm = VibePerfDecoded(name);
            AudioWaveform waveform;
            NSUInteger chunks = waveform.getNumChunks();
            std::vector<float> scratch(65536);
            NSUInteger chunkIndex = 0;
            NSUInteger chunkEnd = pcm->frames / chunks;
            AudioWaveformCacheChunk current;
            for (NSUInteger at = 0; at < pcm->frames; at += 65536) {
                NSUInteger numFrames = MIN((NSUInteger)65536, pcm->frames - at);
                const float *mono = AudioWaveformMonoMix(pcm->interleaved.data() + at * pcm->channels, scratch.data(),
                                                         numFrames, pcm->channels);
                NSUInteger offset = 0;
                while (offset < numFrames && chunkIndex < chunks) {
                    NSUInteger take = MIN(numFrames - offset, chunkEnd - (at + offset));
                    current.mergeFromMonoBuffer(mono + offset, take);
                    offset += take;
                    if (at + offset >= chunkEnd) {
                        waveform.setChunkAtIndex(current, chunkIndex++);
                        current = AudioWaveformCacheChunk();
                        chunkEnd = pcm->frames * (chunkIndex + 1) / chunks;
                    }
                }
            }
        });
    }
}

// MARK: - Benchmarks: the equalizer's analyzer

static void VibePerfRegisterLevels(void) {
    // The render's meter stage on a 48 kHz output, in 512-frame IO cycles,
    // with a summary per cycle as the publisher's drain takes them.
    VibePerfAdd("levels", "render", "audio s", VibePerfPCMPrepare(@"flac-24-96", 48000), []() {
        VibePerfPCM *pcm = VibePerfDecoded(@"flac-24-96");
        VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(48000, (VibeAudioLevelNormalizationMode)0);
        float levels[kLevelBandCount];
        for (NSUInteger at = 0; at + 512 <= pcm->frames; at += 512) {
            float *channels[2] = {pcm->left.data() + at, pcm->right.data() + at};
            VibeAudioLevelAnalyzerConsume(analyzer, channels, 2, 512);
            VibeAudioLevelAnalyzerSummarize(analyzer, levels);
        }
        VibeAudioLevelAnalyzerDestroy(analyzer);
    });
}

// MARK: - Benchmarks: metadata

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
                NSData *displayArt = nil;
                AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:url displayArtData:&displayArt];
                (void)metadata;
            }
        });
    }
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

int VibePerfAnalyzeTree(NSString *root) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSSet *audio = [NSSet setWithArray:@[@"mp3", @"flac", @"wav", @"aiff", @"aif", @"m4a", @"ogg", @"opus"]];
    for (NSString *relative in [NSFileManager.defaultManager enumeratorAtPath:root]) {
        if ([audio containsObject:relative.pathExtension.lowercaseString]) {
            [paths addObject:[root stringByAppendingPathComponent:relative]];
        }
    }
    [paths sortUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSUInteger i = 0; i < paths.count; i++) {
        [lines addObject:@""];
    }
    dispatch_apply(paths.count, DISPATCH_APPLY_AUTO, ^(size_t i) {
        @autoreleasepool {
            AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] init];
            loader.analysisProvider = ^VibeWaveformAnalysis {
                return (VibeWaveformAnalysis){YES, YES};
            };
            CodableAudioWaveform *result = [loader load:paths[i]];
            NSString *line = [NSString stringWithFormat:@"%@\t%.9g\t%ld", paths[i].lastPathComponent,
                              result ? result.bpm : -1.0f, result ? (long)result.key : -2L];
            @synchronized (lines) {
                lines[i] = line;
            }
        }
    });
    for (NSString *line in lines) {
        printf("%s\n", line.UTF8String);
    }
    return 0;
}

VIBE_PERF_REGISTER(VibePerfRegisterDecode)
VIBE_PERF_REGISTER(VibePerfRegisterResample)
VIBE_PERF_REGISTER(VibePerfRegisterWaveform)
VIBE_PERF_REGISTER(VibePerfRegisterLevels)
VIBE_PERF_REGISTER(VibePerfRegisterMetadata)
