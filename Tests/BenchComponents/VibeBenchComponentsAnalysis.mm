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
    const char *passes[] = {"waveform", "waveform+bpm+key", "waveform+bands", "waveform+bpm", "waveform+bands+bpm+key"};
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"flac-24-192", @"aac-256", @"wav-24-96",
                            @"vorbis", @"alac-16-44", @"flac-16-22-mono", @"mp3-320-60min", @"mp3-v0-noxing",
                            @"mp3-320-48k", @"flac-24-88", @"flac-24-176", @"flac-24-352", @"caf-16-44",
                            @"w64-16-44", @"rf64-16-44", @"wav-f32-44", @"wav-5.1-44", @"aac-adts", @"mp2-320"]) {
        for (int analysis = 0; analysis < 2 + 3 * (VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS && VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE); analysis++) {
            auto file = std::make_shared<VibeBenchComponentsFileState>();
            VibeBenchComponentsAdd(passes[analysis], name.UTF8String, "audio s", [name, file]() -> double {
                file->path = VibeBenchComponentsFile(name);
                return VibeBenchComponentsAudioSeconds(file->path);
            }, [file, analysis]() {
                AudioWaveformLoader *loader = VibeBenchComponentsWaveformLoader(analysis == 1 || analysis == 4);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS && VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE
                if (analysis == 2) loader.analysis = (VibeWaveformAnalysis){.bands = YES};
                if (analysis == 3) loader.analysis = (VibeWaveformAnalysis){.bpm = YES};
                if (analysis == 4) loader.analysis = (VibeWaveformAnalysis){.bpm = YES, .key = YES, .bands = YES};
#endif
                CodableAudioWaveform *result = [loader load:file->path];
                VibeBenchComponentsRequire(result != nil && loader.isComplete, "waveform load failed");
            });
        }
    }

#if VIBE_BENCH_COMPONENTS_WAVEFORM_WINDOW
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"aac-256", @"vorbis"]) {
        for (BOOL analysis : {NO, YES}) {
            auto file = std::make_shared<VibeBenchComponentsFileState>();
            VibeBenchComponentsAdd(analysis ? "waveform-window+bpm+key" : "waveform-window", name.UTF8String,
                                  "audio s", [file, name]() -> double {
                file->path = VibeBenchComponentsFile(name);
                return VibeBenchComponentsAudioSeconds(file->path) >= 90 ? 30 : -1;
            }, [file, analysis]() {
                AudioWaveformLoader *loader = VibeBenchComponentsWaveformLoader(analysis);
                loader.cueStart = 60 * 75;
                loader.cueEnd = 90 * 75;
                CodableAudioWaveform *result = [loader load:file->path];
                VibeBenchComponentsRequire(result != nil && loader.isComplete, "CUE waveform load failed");
            });
        }
    }
#endif

#if VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY
    // Detail storage alone: file reads include open, seek, decode and downmix.
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"aac-256", @"vorbis"]) {
        for (const char *operation : {"read", "hit", "evict"}) {
            auto file = std::make_shared<VibeBenchComponentsFileState>();
            auto waveform = std::make_shared<CodableAudioWaveform *>();
            std::string op = operation;
            VibeBenchComponentsAdd("waveform-detail-" + op, name.UTF8String, "block",
                                  [file, waveform, name, op]() -> double {
                file->path = VibeBenchComponentsFile(name);
                if (!file->path) return -1;
                VibeBenchComponentsReader *reader = [[VibeBenchComponentsReader alloc] initWithPath:file->path interleaved:YES];
                VibeBenchComponentsRequire(reader != nil, "detail fixture open failed");
                *waveform = [[CodableAudioWaveform alloc] initWithWaveform:
                        std::make_unique<AudioWaveform>(256, false, reader.processingFormat.sampleRate)];
                if (op == "hit") {
                    AudioWaveformLoader *loader = VibeBenchComponentsWaveformLoader(NO);
                    VibeBenchComponentsRequire([loader loadDetailBlocks:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 8)]
                            ofFile:file->path intoWaveform:*waveform], "detail fixture read failed");
                }
                return op == "evict" ? 32 : 8;
            }, [file, waveform, op]() {
                if (op == "read") {
                    *waveform = [[CodableAudioWaveform alloc] initWithWaveform:
                            std::make_unique<AudioWaveform>(256, false, (*waveform).waveform->sampleRate())];
                }
                AudioWaveformLoader *loader = VibeBenchComponentsWaveformLoader(NO);
                NSUInteger count = op == "evict" ? 32 : 8;
                VibeBenchComponentsRequire([loader loadDetailBlocks:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, count)]
                        ofFile:file->path intoWaveform:*waveform], "waveform detail read failed");
                VibeBenchComponentsRequire((*waveform).waveform->detail().hasBlock(count - 1), "detail block missing");
            });
        }
    }
#endif

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
                std::vector<float> scratch(65536);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY
                wavecore::SummaryBuilder builder(bands, pcm->frames, pcm->rate);
                for (NSUInteger at = 0; at < pcm->frames; at += 65536) {
                    NSUInteger count = MIN((NSUInteger)65536, pcm->frames - at);
                    const float *mono = AudioWaveformMonoMix(pcm->interleaved.data() + at * pcm->channels,
                                                             scratch.data(), count, pcm->channels);
                    builder.append(mono, count);
                }
                builder.finish(true);
#else
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
                AudioWaveform waveform(bands);
                std::unique_ptr<AudioWaveformBandSplit> split =
                        bands ? std::make_unique<AudioWaveformBandSplit>(pcm->rate) : nullptr;
                float bandSums[kAudioWaveformBandCount] = {};
#else
                AudioWaveform waveform;
#endif
                NSUInteger chunks = waveform.getNumChunks();
                NSUInteger chunkIndex = 0;
                NSUInteger chunkEnd = pcm->frames / chunks;
                AudioWaveformCacheChunk current;
                for (NSUInteger at = 0; at < pcm->frames; at += 65536) {
                    NSUInteger numFrames = MIN((NSUInteger)65536, pcm->frames - at);
                    const float *mono = AudioWaveformMonoMix(pcm->interleaved.data() + at * pcm->channels,
                                                             scratch.data(), numFrames, pcm->channels);
                    NSUInteger offset = 0;
                    while (offset < numFrames && chunkIndex < chunks) {
                        NSUInteger take = MIN(numFrames - offset, chunkEnd - (at + offset));
                        current.mergeFromMonoBuffer(mono + offset, take);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
                        if (split) split->addSumSquares(mono + offset, take, bandSums);
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
#endif
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
