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
//  This file is the registry, the shared fixtures and the driver; each
//  VibePerf*.mm beside it registers one area's benchmarks. A benchmark is a
//  body run once per repetition after one warm-up.
//

#import "VibePerf.h"

#import <AVFAudio/AVFAudio.h>

#import "AudioFileHandle.h"
#import "AudioWaveform.h"

#include <libproc.h>
#include <mach/mach_time.h>
#include <regex>
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

void VibePerfAdd(std::string group, std::string variant, const char *unit,
                 std::function<double(void)> prepare, std::function<void(void)> body) {
    VibePerfRegistry().push_back({group + "." + variant, group, unit, std::move(prepare), std::move(body)});
}

static NSString *sCorpus;

NSString *VibePerfCorpus(void) {
    return sCorpus;
}

static std::vector<VibePerfRegistrar> &VibePerfRegistrars(void) {
    static std::vector<VibePerfRegistrar> registrars;
    return registrars;
}

void VibePerfAddRegistrar(VibePerfRegistrar registrar) {
    VibePerfRegistrars().push_back(registrar);
}

NSString *VibePerfFile(NSString *name) {
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

double VibePerfAudioSeconds(NSString *path) {
    AudioFileHandle *file = path ? [[AudioFileHandle alloc] initForReading:[NSURL fileURLWithPath:path] error:nil] : nil;
    return file ? (double)file.length / file.processingFormat.sampleRate : -1;
}

// MARK: - Shared fixtures

VibePerfPCM *VibePerfDecoded(NSString *name) {
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

std::function<double(void)> VibePerfPCMPrepare(NSString *name, double outputRate) {
    return [name, outputRate]() -> double {
        VibePerfPCM *pcm = VibePerfDecoded(name);
        return pcm ? (double)pcm->frames / (outputRate > 0 ? outputRate : pcm->rate) : -1;
    };
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

        for (VibePerfRegistrar registrar : VibePerfRegistrars()) {
            registrar();
        }

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
