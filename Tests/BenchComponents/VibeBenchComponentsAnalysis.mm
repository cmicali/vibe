//
//  VibeBenchComponentsAnalysis.mm
//  VibeBenchComponents
//
//  The waveform pass, the tempo and key analyzers, the waveform's own
//  downmix and chunks, and --analyze.
//

#import "VibeBenchComponents.h"

#import <Accelerate/Accelerate.h>

#import "AudioWaveform.h"
#import "AudioWaveformLoader.h"
#import "AudioBPMAnalyzer.h"
#import "AudioKeyAnalyzer.h"

#include <algorithm>
#include <memory>

// MARK: - Benchmarks: the waveform pass and analysis

static void VibeBenchComponentsRegisterWaveform(void) {
    // The whole cold waveform pass, as the cache runs it: open, pipelined
    // decode, downmix, chunks, with and without both analyzers riding along,
    // and with the band split 3-Band asks for.
    const char *passes[] = {"waveform", "waveform+bpm+key", "waveform+bands"};
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"flac-24-192", @"aac-256", @"wav-24-96"]) {
        for (int analysis = 0; analysis < 2 + (VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS && VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE); analysis++) {
            auto file = std::make_shared<VibeBenchComponentsFileState>();
            VibeBenchComponentsAdd(passes[analysis], name.UTF8String, "audio s", [name, file]() -> double {
                file->path = VibeBenchComponentsFile(name);
                return VibeBenchComponentsAudioSeconds(file->path);
            }, [file, analysis]() {
                AudioWaveformLoader *loader = VibeBenchComponentsWaveformLoader(analysis == 1);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS && VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE
                if (analysis == 2) loader.analysis = (VibeWaveformAnalysis){.bands = YES};
#endif
                CodableAudioWaveform *result = [loader load:file->path];
                (void)result;
            });
        }
    }

    // The analyzers alone, on PCM decoded once: the streaming append at the
    // loader's block size, then the end-of-file estimate.
    for (NSString *name in @[@"flac-16-44", @"flac-24-96"]) {
        std::string n = name.UTF8String;
        VibeBenchComponentsAdd("bpm", n, "audio s", VibeBenchComponentsPCMPrepare(name), [name]() {
            VibeBenchComponentsPCM *pcm = VibeBenchComponentsDecoded(name);
            AudioBPMAnalyzer *analyzer = [[AudioBPMAnalyzer alloc] initWithSampleRate:pcm->rate];
            for (NSUInteger at = 0; at < pcm->frames; at += 65536) {
                [analyzer appendMonoSamples:pcm->mono.data() + at frameCount:MIN((NSUInteger)65536, pcm->frames - at)];
            }
            [analyzer finish];
        });
        VibeBenchComponentsAdd("key", n, "audio s", VibeBenchComponentsPCMPrepare(name), [name]() {
            VibeBenchComponentsPCM *pcm = VibeBenchComponentsDecoded(name);
            AudioKeyAnalyzer *analyzer = [[AudioKeyAnalyzer alloc] initWithSampleRate:pcm->rate];
            for (NSUInteger at = 0; at < pcm->frames; at += 65536) {
                [analyzer appendMonoSamples:pcm->mono.data() + at frameCount:MIN((NSUInteger)65536, pcm->frames - at)];
            }
            [analyzer finish];
        });
        // The loader's processing side without the analyzers: the downmix
        // and the chunk merge over the waveform's chunks, then the same with
        // the band split 3-Band asks for.
        for (int bands = 0; bands <= VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS; bands++) {
            VibeBenchComponentsAdd(bands ? "chunker+bands" : "chunker", n, "audio s",
                                   VibeBenchComponentsPCMPrepare(name), [name, bands]() {
                VibeBenchComponentsPCM *pcm = VibeBenchComponentsDecoded(name);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
                AudioWaveform waveform(bands);
#if VIBE_BENCH_COMPONENTS_BAND_SPLIT_SLICES
                std::unique_ptr<AudioWaveformBandSplit> split =
                        bands ? std::make_unique<AudioWaveformBandSplit>(pcm->rate) : nullptr;
#else
                std::unique_ptr<AudioWaveformBandSplit> split =
                        bands ? std::make_unique<AudioWaveformBandSplit>(pcm->rate, 65536) : nullptr;
#endif
                float bandSums[kAudioWaveformBandCount] = {};
#else
                AudioWaveform waveform;
#endif
                NSUInteger chunks = waveform.getNumChunks();
                std::vector<float> scratch(65536);
                NSUInteger chunkIndex = 0;
                NSUInteger chunkEnd = pcm->frames / chunks;
                AudioWaveformCacheChunk current;
                for (NSUInteger at = 0; at < pcm->frames; at += 65536) {
                    NSUInteger numFrames = MIN((NSUInteger)65536, pcm->frames - at);
                    const float *mono = AudioWaveformMonoMix(pcm->interleaved.data() + at * pcm->channels,
                                                             scratch.data(), numFrames, pcm->channels);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS && !VIBE_BENCH_COMPONENTS_BAND_SPLIT_SLICES
                    if (split) split->process(mono, numFrames);
#endif
                    NSUInteger offset = 0;
                    while (offset < numFrames && chunkIndex < chunks) {
                        NSUInteger take = MIN(numFrames - offset, chunkEnd - (at + offset));
                        current.mergeFromMonoBuffer(mono + offset, take);
#if VIBE_BENCH_COMPONENTS_BAND_SPLIT_SLICES
                        if (split) split->addSumSquares(mono + offset, take, bandSums);
#elif VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
                        if (split) split->addSumSquares(offset, take, bandSums);
#endif
                        offset += take;
                        if (at + offset >= chunkEnd) {
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
                            waveform.setBandSumSquaresAtIndex(bandSums, chunkIndex);
                            std::fill(bandSums, bandSums + kAudioWaveformBandCount, 0.0f);
#endif
                            waveform.setChunkAtIndex(current, chunkIndex++);
                            current = AudioWaveformCacheChunk();
                            chunkEnd = pcm->frames * (chunkIndex + 1) / chunks;
                        }
                    }
                }
            });
        }
    }
}

static int VibeBenchComponentsAnalyzeTree(NSString *root) {
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
            AudioWaveformLoader *loader = VibeBenchComponentsWaveformLoader(YES);
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

static void VibeBenchComponentsRegisterAnalyzeTree(void) {
    VibeBenchComponentsSetAnalyzeTree(VibeBenchComponentsAnalyzeTree);
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterWaveform)
VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterAnalyzeTree)
