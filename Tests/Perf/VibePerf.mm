//
//  VibePerf.mm
//  VibePerf
//
//  The micro-benchmark suite: production code driven in-process, one named
//  benchmark at a time, each measured as wall time and as the instructions
//  and cycles the whole process retired (proc_pid_rusage), which stay
//  comparable on a loaded machine where wall time does not. The vibe-perf
//  skill builds it at two refs and compares them; run it alone with --help.
//
//  A benchmark is a body run once per repetition after one warm-up. Corpus
//  files are named by their basename without extension; a benchmark whose
//  file is missing is skipped, so a partial corpus still runs.
//

#import <AVFAudio/AVFAudio.h>
#import <Accelerate/Accelerate.h>
#import <AppKit/AppKit.h>

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

#include <libproc.h>
#include <mach/mach_time.h>
#include <regex>
#include <string>
#include <vector>
#include <functional>
#include <algorithm>

// MARK: - Measurement

struct VibePerfSample {
    double wallMs;
    double cpuMs;
    double instructions;
    double cycles;
};

static uint64_t VibePerfNow(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static struct rusage_info_v4 VibePerfUsage(void) {
    struct rusage_info_v4 info = {};
    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&info);
    return info;
}

static double VibePerfMachToMs(uint64_t mach) {
    static mach_timebase_info_data_t base;
    if (base.denom == 0) {
        mach_timebase_info(&base);
    }
    return (double)mach * base.numer / base.denom / 1e6;
}

static VibePerfSample VibePerfMeasure(const std::function<void(void)> &body) {
    struct rusage_info_v4 before = VibePerfUsage();
    uint64_t start = VibePerfNow();
    @autoreleasepool {
        body();
    }
    uint64_t end = VibePerfNow();
    struct rusage_info_v4 after = VibePerfUsage();
    VibePerfSample sample;
    sample.wallMs = (double)(end - start) / 1e6;
    sample.cpuMs = VibePerfMachToMs((after.ri_user_time + after.ri_system_time) - (before.ri_user_time + before.ri_system_time));
    sample.instructions = (double)(after.ri_instructions - before.ri_instructions);
    sample.cycles = (double)(after.ri_cycles - before.ri_cycles);
    return sample;
}

static double VibePerfMedian(std::vector<double> values) {
    if (values.empty()) {
        return 0;
    }
    std::sort(values.begin(), values.end());
    size_t n = values.size();
    return n % 2 ? values[n / 2] : (values[n / 2 - 1] + values[n / 2]) / 2;
}

// MARK: - Registry

struct VibePerfBench {
    std::string name;
    std::string group;
    // What one repetition's per-unit column divides by: "audio s" reports a
    // realtime factor from CPU time, anything else wall ms per unit.
    const char *unit;
    // Run before the warm-up, outside every measurement: the units of work
    // one repetition does, or a negative number to skip (a missing corpus file).
    std::function<double(void)> prepare;
    std::function<void(void)> body;
};

static std::vector<VibePerfBench> &VibePerfRegistry(void) {
    static std::vector<VibePerfBench> registry;
    return registry;
}

static void VibePerfAdd(std::string group, std::string variant, const char *unit,
                        std::function<double(void)> prepare, std::function<void(void)> body) {
    VibePerfRegistry().push_back({group + "." + variant, group, unit, std::move(prepare), std::move(body)});
}

static NSString *sCorpus;

static NSString *VibePerfFile(NSString *name) {
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *folder in @[@"play", @"extra"]) {
        NSString *dir = [sCorpus stringByAppendingPathComponent:folder];
        for (NSString *entry in [manager contentsOfDirectoryAtPath:dir error:nil]) {
            if ([entry.stringByDeletingPathExtension isEqualToString:name] && ![entry containsString:@".tmp."]) {
                return [dir stringByAppendingPathComponent:entry];
            }
        }
    }
    return nil;
}

static double VibePerfAudioSeconds(NSString *path) {
    AudioFileHandle *file = path ? [[AudioFileHandle alloc] initForReading:[NSURL fileURLWithPath:path] error:nil] : nil;
    return file ? (double)file.length / file.processingFormat.sampleRate : -1;
}

// A corpus file resolved at prepare time, shared by a benchmark's two lambdas.
struct VibePerfFileState {
    NSString *path;
};

// MARK: - Shared fixtures

// One file decoded once to interleaved float32, for the benchmarks that start
// from PCM (analysis, chunker, levels).
struct VibePerfPCM {
    std::vector<float> interleaved;
    std::vector<float> mono;
    std::vector<float> left;
    std::vector<float> right;
    double rate = 0;
    NSUInteger channels = 0;
    NSUInteger frames = 0;
};

static VibePerfPCM *VibePerfDecoded(NSString *name) {
    static NSMutableDictionary<NSString *, NSValue *> *cache;
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
    }
    NSValue *hit = cache[name];
    if (hit) {
        return (VibePerfPCM *)hit.pointerValue;
    }
    NSString *path = VibePerfFile(name);
    AudioFileHandle *file = path ? [[AudioFileHandle alloc] initForReading:[NSURL fileURLWithPath:path]
                                                              commonFormat:AVAudioPCMFormatFloat32
                                                               interleaved:YES
                                                                     error:nil] : nil;
    if (!file) {
        return nullptr;
    }
    VibePerfPCM *pcm = new VibePerfPCM();
    pcm->rate = file.processingFormat.sampleRate;
    pcm->channels = file.processingFormat.channelCount;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:65536];
    while ([file readIntoBuffer:buffer error:nil] && buffer.frameLength > 0) {
        const float *data = buffer.floatChannelData[0];
        pcm->interleaved.insert(pcm->interleaved.end(), data, data + (size_t)buffer.frameLength * pcm->channels);
    }
    pcm->frames = pcm->interleaved.size() / pcm->channels;
    pcm->mono.resize(pcm->frames);
    const float *mono = AudioWaveformMonoMix(pcm->interleaved.data(), pcm->mono.data(), pcm->frames, pcm->channels);
    if (mono != pcm->mono.data()) {
        memcpy(pcm->mono.data(), mono, pcm->frames * sizeof(float));
    }
    pcm->left.resize(pcm->frames);
    pcm->right.resize(pcm->frames);
    for (NSUInteger f = 0; f < pcm->frames; f++) {
        pcm->left[f] = pcm->interleaved[f * pcm->channels];
        pcm->right[f] = pcm->interleaved[f * pcm->channels + (pcm->channels > 1 ? 1 : 0)];
    }
    cache[name] = [NSValue valueWithPointer:pcm];
    return pcm;
}

static std::function<double(void)> VibePerfPCMPrepare(NSString *name, double outputRate = 0) {
    return [name, outputRate]() -> double {
        VibePerfPCM *pcm = VibePerfDecoded(name);
        return pcm ? (double)pcm->frames / (outputRate > 0 ? outputRate : pcm->rate) : -1;
    };
}

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
                                                                 commonFormat:AVAudioPCMFormatFloat32
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
        NSString *library = [sCorpus stringByAppendingPathComponent:@"library"];
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

// MARK: - Driver

static void VibePerfUsageText(void) {
    printf("usage: VibePerf --corpus <dir> [--reps N] [--filter <regex>] [--json <out>] [--list] [--loop <seconds>]\n"
           "  --corpus   the corpus root (play/, extra/, library/); default build/bench/corpus\n"
           "  --reps     measured repetitions per benchmark, after one warm-up (default 5)\n"
           "  --filter   ECMAScript regex over benchmark names\n"
           "  --json     write every sample as JSON\n"
           "  --list     print the benchmark names and exit\n"
           "  --loop     run each selected benchmark repeatedly for that long, unmeasured, for a profiler\n");
}

int main(int argc, const char *argv[]) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    @autoreleasepool {
        sCorpus = @"build/bench/corpus";
        int reps = 5;
        std::string filter = ".*";
        NSString *jsonPath = nil;
        BOOL list = NO;
        double loopSeconds = 0;
        for (int i = 1; i < argc; i++) {
            std::string arg = argv[i];
            BOOL hasValue = i + 1 < argc;
            if (arg == "--corpus" && hasValue) {
                sCorpus = @(argv[++i]);
            } else if (arg == "--reps" && hasValue) {
                reps = atoi(argv[++i]);
                reps = MAX(1, reps);
            } else if (arg == "--filter" && hasValue) {
                filter = argv[++i];
            } else if (arg == "--json" && hasValue) {
                jsonPath = @(argv[++i]);
            } else if (arg == "--loop" && hasValue) {
                loopSeconds = atof(argv[++i]);
            } else if (arg == "--list") {
                list = YES;
            } else {
                VibePerfUsageText();
                return arg == "--help" || arg == "-h" ? 0 : 64;
            }
        }

        VibePerfRegisterDecode();
        VibePerfRegisterResample();
        VibePerfRegisterWaveform();
        VibePerfRegisterLevels();
        VibePerfRegisterMetadata();

        std::regex selector(filter);
        NSMutableDictionary *results = [NSMutableDictionary dictionary];
        if (!list) {
            printf("%-34s %10s %10s %12s %10s %12s\n", "benchmark", "wall ms", "cpu ms", "Minstr", "Mcycles", "per unit");
        }
        for (auto &bench : VibePerfRegistry()) {
            if (!std::regex_search(bench.name, selector)) {
                continue;
            }
            if (list) {
                printf("%s\n", bench.name.c_str());
                continue;
            }
            double units = bench.prepare();
            if (units < 0) {
                printf("%-34s skipped (missing corpus file)\n", bench.name.c_str());
                continue;
            }
            if (loopSeconds > 0) {
                uint64_t until = VibePerfNow() + (uint64_t)(loopSeconds * 1e9);
                int runs = 0;
                while (VibePerfNow() < until) {
                    @autoreleasepool {
                        bench.body();
                    }
                    runs++;
                }
                printf("%-34s looped %d times\n", bench.name.c_str(), runs);
                continue;
            }
            VibePerfMeasure(bench.body);
            std::vector<double> wall, cpu, instructions, cycles;
            for (int r = 0; r < reps; r++) {
                VibePerfSample sample = VibePerfMeasure(bench.body);
                wall.push_back(sample.wallMs);
                cpu.push_back(sample.cpuMs);
                instructions.push_back(sample.instructions);
                cycles.push_back(sample.cycles);
            }
            double medianInstructions = VibePerfMedian(instructions);
            std::string perUnit = "";
            if (units > 0) {
                char text[64];
                if (strcmp(bench.unit, "audio s") == 0) {
                    snprintf(text, sizeof(text), "%.0fx rt", units * 1000.0 / VibePerfMedian(cpu));
                } else {
                    snprintf(text, sizeof(text), "%.3f ms/%s", VibePerfMedian(wall) / units, bench.unit);
                }
                perUnit = text;
            }
            printf("%-34s %10.2f %10.2f %12.2f %10.2f %12s\n", bench.name.c_str(), VibePerfMedian(wall), VibePerfMedian(cpu),
                   medianInstructions / 1e6, VibePerfMedian(cycles) / 1e6, perUnit.c_str());
            fflush(stdout);
            NSMutableArray *(^array)(const std::vector<double> &) = ^(const std::vector<double> &values) {
                NSMutableArray *out = [NSMutableArray array];
                for (double v : values) {
                    [out addObject:@(v)];
                }
                return out;
            };
            results[@(bench.name.c_str())] = @{
                @"group": @(bench.group.c_str()),
                @"units": @(units),
                @"unit": @(bench.unit),
                @"wall_ms": array(wall),
                @"cpu_ms": array(cpu),
                @"instructions": array(instructions),
                @"cycles": array(cycles),
            };
        }
        if (jsonPath && results.count) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"reps": @(reps), @"benches": results}
                                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                             error:nil];
            [data writeToFile:jsonPath atomically:YES];
        }
    }
    return 0;
}
