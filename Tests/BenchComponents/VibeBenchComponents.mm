//
//  VibeBenchComponents.mm
//  VibeBenchComponents
//
//  The micro-benchmark suite: production code driven in-process, one named
//  benchmark at a time, each measured as wall time and as the instructions
//  and cycles the whole process retired (proc_pid_rusage), which stay
//  comparable on a loaded machine where wall time does not. The vibe-perf
//  skill builds it at two refs and compares them; run it alone with --help.
//
//  This file is the registry, the shared fixtures and the driver; each
//  VibeBenchComponents*.mm beside it registers one area's benchmarks. A benchmark is a
//  body run once per repetition after one warm-up.
//

#import "VibeBenchComponents.h"

#import <AVFAudio/AVFAudio.h>

#import "AppSettings.h"
#import "AudioWaveformLoader.h"
#if VIBE_BENCH_COMPONENTS_FILE_HANDLE
#import "AudioFileHandle.h"
#endif
#if VIBE_BENCH_COMPONENTS_AVF_WAVEFORM_LOADER
#import "AVFAudioWaveformLoader.h"
#endif

#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <regex>
#include <algorithm>

// MARK: - Measurement

struct VibeBenchComponentsSample {
    double wallMs;
    double cpuMs;
    double instructions;
    double cycles;
    double syscalls;  // Unix system calls, every thread: reads, opens, stats
};

static uint64_t VibeBenchComponentsNow(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static struct rusage_info_v4 VibeBenchComponentsUsage(void) {
    struct rusage_info_v4 info = {};
    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&info);
    return info;
}

static double VibeBenchComponentsMachToMs(uint64_t mach) {
    static mach_timebase_info_data_t base;
    if (base.denom == 0) {
        mach_timebase_info(&base);
    }
    return (double)mach * base.numer / base.denom / 1e6;
}

static double VibeBenchComponentsSyscalls(void) {
    task_events_info_data_t events = {};
    mach_msg_type_number_t count = TASK_EVENTS_INFO_COUNT;
    task_info(mach_task_self(), TASK_EVENTS_INFO, (task_info_t)&events, &count);
    return (double)events.syscalls_unix;
}

static VibeBenchComponentsSample VibeBenchComponentsMeasure(const std::function<void(void)> &body) {
    double syscallsBefore = VibeBenchComponentsSyscalls();
    struct rusage_info_v4 before = VibeBenchComponentsUsage();
    uint64_t start = VibeBenchComponentsNow();
    @autoreleasepool {
        body();
    }
    uint64_t end = VibeBenchComponentsNow();
    struct rusage_info_v4 after = VibeBenchComponentsUsage();
    VibeBenchComponentsSample sample;
    sample.wallMs = (double)(end - start) / 1e6;
    sample.cpuMs = VibeBenchComponentsMachToMs((after.ri_user_time + after.ri_system_time) - (before.ri_user_time + before.ri_system_time));
    sample.instructions = (double)(after.ri_instructions - before.ri_instructions);
    sample.cycles = (double)(after.ri_cycles - before.ri_cycles);
    sample.syscalls = VibeBenchComponentsSyscalls() - syscallsBefore;
    return sample;
}

static double VibeBenchComponentsMedian(std::vector<double> values) {
    if (values.empty()) {
        return 0;
    }
    std::sort(values.begin(), values.end());
    size_t n = values.size();
    return n % 2 ? values[n / 2] : (values[n / 2 - 1] + values[n / 2]) / 2;
}

// MARK: - Registry

struct VibeBenchComponentsBench {
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

static std::vector<VibeBenchComponentsBench> &VibeBenchComponentsRegistry(void) {
    static std::vector<VibeBenchComponentsBench> registry;
    return registry;
}

void VibeBenchComponentsAdd(std::string group, std::string variant, const char *unit,
                 std::function<double(void)> prepare, std::function<void(void)> body) {
    VibeBenchComponentsRegistry().push_back({group + "." + variant, group, unit, std::move(prepare), std::move(body)});
}

static NSString *sCorpus;

NSString *VibeBenchComponentsCorpus(void) {
    return sCorpus;
}

static std::vector<VibeBenchComponentsRegistrar> &VibeBenchComponentsRegistrars(void) {
    static std::vector<VibeBenchComponentsRegistrar> registrars;
    return registrars;
}

void VibeBenchComponentsAddRegistrar(VibeBenchComponentsRegistrar registrar) {
    VibeBenchComponentsRegistrars().push_back(registrar);
}

NSString *VibeBenchComponentsFile(NSString *name) {
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *folder in @[@"play", @"extra"]) {
        NSString *dir = [sCorpus stringByAppendingPathComponent:folder];
        for (NSString *entry in [manager contentsOfDirectoryAtPath:dir error:nil]) {
            if ([entry.stringByDeletingPathExtension isEqualToString:name]) {
                return [dir stringByAppendingPathComponent:entry];
            }
        }
    }
    return nil;
}

@implementation VibeBenchComponentsReader {
#if VIBE_BENCH_COMPONENTS_FILE_HANDLE
    AudioFileHandle *_handle;
#endif
    AVAudioFile *_file;
}

- (instancetype)initWithPath:(NSString *)path interleaved:(BOOL)interleaved {
    self = [super init];
    NSURL *url = path ? [NSURL fileURLWithPath:path] : nil;
    if (!self || !url) {
        return nil;
    }
#if VIBE_BENCH_COMPONENTS_FILE_HANDLE
#if VIBE_BENCH_COMPONENTS_FILE_HANDLE_COMMON_FORMAT
    _handle = interleaved ? [[AudioFileHandle alloc] initForReading:url commonFormat:AVAudioPCMFormatFloat32
                                                         interleaved:YES error:nil]
                          : [[AudioFileHandle alloc] initForReading:url error:nil];
#else
    _handle = interleaved ? [[AudioFileHandle alloc] initForReading:url interleaved:YES error:nil]
                          : [[AudioFileHandle alloc] initForReading:url error:nil];
#endif
    return _handle ? self : nil;
#else
    _file = [[AVAudioFile alloc] initForReading:url commonFormat:AVAudioPCMFormatFloat32 interleaved:interleaved error:nil];
    return _file ? self : nil;
#endif
}

- (AVAudioFormat *)processingFormat {
#if VIBE_BENCH_COMPONENTS_FILE_HANDLE
    return _handle.processingFormat;
#else
    return _file.processingFormat;
#endif
}

- (long long)length {
#if VIBE_BENCH_COMPONENTS_FILE_HANDLE
    return _handle.length;
#else
    return _file.length;
#endif
}

- (BOOL)read:(AVAudioPCMBuffer *)buffer {
#if VIBE_BENCH_COMPONENTS_FILE_HANDLE
    return [_handle readIntoBuffer:buffer error:nil] && buffer.frameLength > 0;
#else
    return [_file readIntoBuffer:buffer error:nil] && buffer.frameLength > 0;
#endif
}

- (void)seekTo:(long long)frame {
#if VIBE_BENCH_COMPONENTS_FILE_HANDLE
    [_handle seekToFrame:frame error:nil];
#else
    _file.framePosition = frame;
#endif
}

@end

double VibeBenchComponentsAudioSeconds(NSString *path) {
    VibeBenchComponentsReader *reader = [[VibeBenchComponentsReader alloc] initWithPath:path interleaved:NO];
    return reader ? (double)reader.length / reader.processingFormat.sampleRate : -1;
}

id VibeBenchComponentsWaveformLoader(BOOL analyzers) {
#if VIBE_BENCH_COMPONENTS_AVF_WAVEFORM_LOADER
    AudioWaveformLoader *loader = [[AVFAudioWaveformLoader alloc] init];
#else
    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] init];
#endif
#if VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE
    if (analyzers) {
        loader.analysis = (VibeWaveformAnalysis){.bpm = YES, .key = YES};
    }
#elif VIBE_BENCH_COMPONENTS_ANALYSIS_PROVIDER
    if (analyzers) {
        loader.analysisProvider = ^VibeWaveformAnalysis {
            return (VibeWaveformAnalysis){YES, YES};
        };
    }
#else
    // Before the provider the loader read the two settings itself; a version
    // that lacks one throws, and that analyzer simply does not run.
    for (NSString *key in @[@"analyzeBPM", @"analyzeKey"]) {
        @try {
            [AppSettings.sharedInstance setValue:@(analyzers) forKey:key];
        } @catch (NSException *exception) {
        }
    }
#endif
    return loader;
}

static VibeBenchComponentsAnalyzeTreeFunction sAnalyzeTree;

void VibeBenchComponentsSetAnalyzeTree(VibeBenchComponentsAnalyzeTreeFunction function) {
    sAnalyzeTree = function;
}

// MARK: - Shared fixtures

VibeBenchComponentsPCM *VibeBenchComponentsDecoded(NSString *name) {
    static NSMutableDictionary<NSString *, NSValue *> *cache;
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
    }
    NSValue *hit = cache[name];
    if (hit) {
        return (VibeBenchComponentsPCM *)hit.pointerValue;
    }
    VibeBenchComponentsReader *file = [[VibeBenchComponentsReader alloc] initWithPath:VibeBenchComponentsFile(name) interleaved:YES];
    if (!file) {
        return nullptr;
    }
    VibeBenchComponentsPCM *pcm = new VibeBenchComponentsPCM();
    pcm->rate = file.processingFormat.sampleRate;
    pcm->channels = file.processingFormat.channelCount;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:65536];
    while ([file read:buffer]) {
        const float *data = buffer.floatChannelData[0];
        pcm->interleaved.insert(pcm->interleaved.end(), data, data + (size_t)buffer.frameLength * pcm->channels);
    }
    pcm->frames = pcm->interleaved.size() / pcm->channels;
    // A fixture, so a plain average: the loader's own downmix is what the
    // chunker benchmark measures.
    pcm->mono.resize(pcm->frames);
    for (NSUInteger f = 0; f < pcm->frames; f++) {
        float sum = 0;
        for (NSUInteger c = 0; c < pcm->channels; c++) {
            sum += pcm->interleaved[f * pcm->channels + c];
        }
        pcm->mono[f] = sum / (float)pcm->channels;
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

std::function<double(void)> VibeBenchComponentsPCMPrepare(NSString *name, double outputRate) {
    return [name, outputRate]() -> double {
        VibeBenchComponentsPCM *pcm = VibeBenchComponentsDecoded(name);
        return pcm ? (double)pcm->frames / (outputRate > 0 ? outputRate : pcm->rate) : -1;
    };
}

// MARK: - Temporary files

static NSMutableArray<NSString *> *VibeBenchComponentsTemporaryRoots(void) {
    static NSMutableArray<NSString *> *roots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        roots = [NSMutableArray array];
        atexit_b(^{
            for (NSString *root in roots) {
                [NSFileManager.defaultManager removeItemAtPath:root error:nil];
            }
        });
    });
    return roots;
}

// A fresh directory, removed when the process exits.
NSString *VibeBenchComponentsTemporaryDirectory(NSString *label) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"vibe-perf-%@-%@", label, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    [VibeBenchComponentsTemporaryRoots() addObject:root];
    return root;
}

// Set by a wait that ran out, so the driver fails the benchmark it ran in.
static BOOL sWaitTimedOut;

// Runs the main queue, where metadata deliveries land, until done or a
// generous bound; running out fails the benchmark.
void VibeBenchComponentsSpinMainUntil(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:600];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, true);
    }
    if (!done()) {
        sWaitTimedOut = YES;
    }
}

// `count` one-byte files in folders of 100, the relative paths returned.
NSArray<NSString *> *VibeBenchComponentsMakeFiles(NSString *root, NSUInteger count, NSString *extension) {
    NSMutableArray<NSString *> *relative = [NSMutableArray arrayWithCapacity:count];
    NSData *byte = [NSData dataWithBytes:"\1" length:1];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *folder = [NSString stringWithFormat:@"Artist %03lu/Album %03lu", (unsigned long)(i / 1000),
                                                      (unsigned long)(i / 100)];
        if (i % 100 == 0) {
            [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:folder]
                                    withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSString *path = [folder stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%02lu Track %lu.%@", (unsigned long)(i % 100 + 1), (unsigned long)i, extension]];
        [byte writeToFile:[root stringByAppendingPathComponent:path] atomically:NO];
        [relative addObject:path];
    }
    return relative;
}

// MARK: - Driver

static void VibeBenchComponentsUsageText(void) {
    printf("usage: VibeBenchComponents --corpus <dir> [--reps N] [--filter <regex>] [--json <out>] [--list] [--loop <seconds>] [--analyze <dir>]\n"
           "  --corpus   the corpus root (play/, extra/, library/); default build/bench/corpus\n"
           "  --reps     measured repetitions per benchmark, after one warm-up (default 5)\n"
           "  --filter   ECMAScript regex over benchmark names\n"
           "  --json     write every sample as JSON\n"
           "  --list     print the benchmark names and exit\n"
           "  --loop     run each selected benchmark repeatedly for that long, unmeasured, for a profiler\n"
           "  --analyze  print tempo and key for every audio file under a folder, and exit\n");
}

int main(int argc, const char *argv[]) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    @autoreleasepool {
        sCorpus = @"build/bench/corpus";
        for (VibeBenchComponentsRegistrar registrar : VibeBenchComponentsRegistrars()) {
            registrar();
        }
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
            } else if (arg == "--analyze" && hasValue) {
                if (!sAnalyzeTree) {
                    fprintf(stderr, "this version's build has no analysis benchmarks\n");
                    return 69;
                }
                return sAnalyzeTree(@(argv[++i]));
            } else if (arg == "--list") {
                list = YES;
            } else {
                VibeBenchComponentsUsageText();
                return arg == "--help" || arg == "-h" ? 0 : 64;
            }
        }

        std::regex selector(filter);
        NSMutableDictionary *results = [NSMutableDictionary dictionary];
        if (!list) {
            printf("%-34s %10s %10s %12s %10s %9s %12s\n", "benchmark", "wall ms", "cpu ms", "Minstr", "Mcycles", "syscalls", "per unit");
        }
        for (auto &bench : VibeBenchComponentsRegistry()) {
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
                uint64_t until = VibeBenchComponentsNow() + (uint64_t)(loopSeconds * 1e9);
                int runs = 0;
                while (VibeBenchComponentsNow() < until) {
                    @autoreleasepool {
                        bench.body();
                    }
                    runs++;
                }
                printf("%-34s looped %d times\n", bench.name.c_str(), runs);
                continue;
            }
            sWaitTimedOut = NO;
            VibeBenchComponentsMeasure(bench.body);
            std::vector<double> wall, cpu, instructions, cycles, syscalls;
            for (int r = 0; r < reps && !sWaitTimedOut; r++) {
                VibeBenchComponentsSample sample = VibeBenchComponentsMeasure(bench.body);
                wall.push_back(sample.wallMs);
                cpu.push_back(sample.cpuMs);
                instructions.push_back(sample.instructions);
                cycles.push_back(sample.cycles);
                syscalls.push_back(sample.syscalls);
            }
            // Absent from the JSON, as perf.py reads a benchmark a version
            // cannot build, rather than a stopped clock in the median.
            if (sWaitTimedOut) {
                fprintf(stderr, "%-34s FAILED: a wait timed out; left out of the results\n", bench.name.c_str());
                continue;
            }
            double medianInstructions = VibeBenchComponentsMedian(instructions);
            std::string perUnit = "";
            if (units > 0) {
                char text[64];
                if (strcmp(bench.unit, "audio s") == 0) {
                    snprintf(text, sizeof(text), "%.0fx rt", units * 1000.0 / VibeBenchComponentsMedian(cpu));
                } else {
                    snprintf(text, sizeof(text), "%.3f ms/%s", VibeBenchComponentsMedian(wall) / units, bench.unit);
                }
                perUnit = text;
            }
            printf("%-34s %10.2f %10.2f %12.2f %10.2f %9.0f %12s\n", bench.name.c_str(), VibeBenchComponentsMedian(wall), VibeBenchComponentsMedian(cpu),
                   medianInstructions / 1e6, VibeBenchComponentsMedian(cycles) / 1e6, VibeBenchComponentsMedian(syscalls), perUnit.c_str());
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
                @"syscalls": array(syscalls),
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
