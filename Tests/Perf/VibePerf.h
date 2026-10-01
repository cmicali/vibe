//
//  VibePerf.h
//  VibePerf
//
//  The suite's shared surface: the registry each benchmark file adds to, and
//  the corpus and fixtures they share. A benchmark file registers itself with
//  VIBE_PERF_REGISTER, so adding one touches no other file.
//

#import <Foundation/Foundation.h>

#include <functional>
#include <string>
#include <vector>

// "audio s" reports a realtime factor from CPU time; any other unit, wall ms
// per unit. prepare runs outside every measurement and answers the units of
// work one repetition does, or a negative number to skip (a missing corpus
// file); body is the measured repetition.
void VibePerfAdd(std::string group, std::string variant, const char *unit,
                 std::function<double(void)> prepare, std::function<void(void)> body);

typedef void (*VibePerfRegistrar)(void);
void VibePerfAddRegistrar(VibePerfRegistrar registrar);
#define VIBE_PERF_REGISTER(function) \
    __attribute__((constructor)) static void function##Registration(void) { VibePerfAddRegistrar(function); }

// The corpus root (play/, extra/, library/).
NSString *VibePerfCorpus(void);
// A corpus file by its basename without extension, from play/ or extra/; nil
// when absent.
NSString *VibePerfFile(NSString *name);
// The file's length in seconds through AudioFileHandle; negative when it
// cannot be opened.
double VibePerfAudioSeconds(NSString *path);

// A corpus file resolved at prepare time, shared by a benchmark's two lambdas.
struct VibePerfFileState {
    NSString *path;
};

// One file decoded once to float32, for the benchmarks that start from PCM.
struct VibePerfPCM {
    std::vector<float> interleaved;
    std::vector<float> mono;
    std::vector<float> left;
    std::vector<float> right;
    double rate = 0;
    NSUInteger channels = 0;
    NSUInteger frames = 0;
};

// Decoded on first use and kept; nullptr when the file is missing.
VibePerfPCM *VibePerfDecoded(NSString *name);
// A prepare answering that file's seconds, at `outputRate` when nonzero.
std::function<double(void)> VibePerfPCMPrepare(NSString *name, double outputRate = 0);
