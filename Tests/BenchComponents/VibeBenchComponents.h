//
//  VibeBenchComponents.h
//  VibeBenchComponents
//
//  The suite's shared surface: the registry each benchmark file adds to, and
//  the corpus and fixtures they share. A benchmark file registers itself with
//  VIBE_BENCH_COMPONENTS_REGISTER, so adding one touches no other file.
//

#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>

// What the code being measured has, so one harness builds against every
// release back to 1.8. perf.py writes VibeBenchComponentsFeatures.h into an older
// checkout it grafts the harness onto, from that checkout's own sources; the
// working tree has none, and gets the current answers below. A benchmark file
// that still cannot compile against a version is left out of that version's
// build, so its benchmarks read as absent rather than failing the run.
#if __has_include("VibeBenchComponentsFeatures.h")
#include "VibeBenchComponentsFeatures.h"
#else
#define VIBE_BENCH_COMPONENTS_FILE_HANDLE 1               // AudioFileHandle (1.14 on); AVAudioFile before
#define VIBE_BENCH_COMPONENTS_FILE_HANDLE_COMMON_FORMAT 0 // its interleaved init took a common format
#define VIBE_BENCH_COMPONENTS_AVF_WAVEFORM_LOADER 0       // the loader was the AVFAudioWaveformLoader subclass
#define VIBE_BENCH_COMPONENTS_ANALYSIS_PROVIDER 1         // the loader asks a provider (1.10 on); settings before
#define VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE 1            // the loader takes the provider's answer as a value
#define VIBE_BENCH_COMPONENTS_METADATA_DISPLAY_ART 1      // metadataWithURL:displayArtData:
#define VIBE_BENCH_COMPONENTS_LEVELS_SUMMARIZE 1          // the meter summarizes apart from consuming (1.14 on)
#define VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS 1            // a waveform can hold the three bands' energies
#define VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY 1          // the waveform is wavecore's summary, not 8,192 chunks
#define VIBE_BENCH_COMPONENTS_WAVEFORM_COMPLETE 1         // a waveform is marked complete (1.14 on); always complete before
#define VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER 1           // renderers draw pictures into layer contents; no paths or bakes
#define VIBE_BENCH_COMPONENTS_WAVEFORM_MIX_ONLY 1         // a summary keeps the mix alone, so it takes no channels
#define VIBE_BENCH_COMPONENTS_WAVEFORM_SPECTRUM 1         // SpectrumWaveformRenderer exists
#define VIBE_BENCH_COMPONENTS_VIBE_RESAMPLER 1            // the resampler is VibeResampler*; VibeConverter* before
#define VIBE_BENCH_COMPONENTS_WAVEFORM_DRAW 1             // registry construction
#define VIBE_BENCH_COMPONENTS_WAVEFORM_BAKE 0             // the separate envelope bake
#define VIBE_BENCH_COMPONENTS_APPLE_MPEG 0                // the selectable MPEG decoder (1.14 to 1.16)
#define VIBE_BENCH_COMPONENTS_WAVEFORM_WINDOW 1           // loader CUE windows
#define VIBE_BENCH_COMPONENTS_SPECTRUM_SECTIONS 1         // VibeSpectrumSections answers By section's sections
#define VIBE_BENCH_COMPONENTS_WAVEFORM_OBSERVERS 1        // the app attaches the analyzers as observers; flags before
#define VIBE_BENCH_COMPONENTS_PLAYLIST_KEYS 1             // the playlist reads its entries through key blocks
#endif

#include <functional>
#include <string>
#include <vector>

// "audio s" reports a realtime factor from CPU time; any other unit, wall ms
// per unit. prepare runs outside every measurement and answers the units of
// work one repetition does, or a negative number to skip (a missing corpus
// file); body is the measured repetition.
void VibeBenchComponentsAdd(std::string group, std::string variant, const char *unit,
                 std::function<double(void)> prepare, std::function<void(void)> body);

// A failed operation must not become a faster benchmark result.
void VibeBenchComponentsRequire(BOOL condition, const char *message);

typedef void (*VibeBenchComponentsRegistrar)(void);
void VibeBenchComponentsAddRegistrar(VibeBenchComponentsRegistrar registrar);
#define VIBE_BENCH_COMPONENTS_REGISTER(function) \
    __attribute__((constructor)) static void function##Registration(void) { VibeBenchComponentsAddRegistrar(function); }

// The corpus root (play/, extra/, library/).
NSString *VibeBenchComponentsCorpus(void);
// A corpus file by its basename without extension, from play/ or extra/; nil
// when absent.
NSString *VibeBenchComponentsFile(NSString *name);
// The file's length in seconds through the player's reader; negative when it
// cannot be opened.
double VibeBenchComponentsAudioSeconds(NSString *path);

// The player's file reader in the version measured: AudioFileHandle where it
// exists, AVAudioFile before it (1.13 and earlier read through that), float32
// planar or interleaved.
@interface VibeBenchComponentsReader : NSObject
- (instancetype)initWithPath:(NSString *)path interleaved:(BOOL)interleaved;
@property (nonatomic, readonly) AVAudioFormat *processingFormat;
@property (nonatomic, readonly) long long length;
// Fills the buffer to its capacity; NO at EOF. A read failure fails the run.
- (BOOL)read:(AVAudioPCMBuffer *)buffer;
- (BOOL)read:(AVAudioPCMBuffer *)buffer frames:(AVAudioFrameCount)frames;
- (void)seekTo:(long long)frame;
@end

// A waveform loader of the version's own class, both analyzers on or off.
// Returns the loader (an AudioWaveformLoader); load: it with a path.
id VibeBenchComponentsWaveformLoader(BOOL analyzers);

// A corpus file resolved at prepare time, shared by a benchmark's two lambdas.
struct VibeBenchComponentsFileState {
    NSString *path;
};

// One file decoded once to float32, for the benchmarks that start from PCM.
struct VibeBenchComponentsPCM {
    std::vector<float> interleaved;
    std::vector<float> mono;
    std::vector<float> left;
    std::vector<float> right;
    double rate = 0;
    NSUInteger channels = 0;
    NSUInteger frames = 0;
};

// Decoded on first use and kept; nullptr when the file is missing.
VibeBenchComponentsPCM *VibeBenchComponentsDecoded(NSString *name);
// A prepare answering that file's seconds, at `outputRate` when nonzero.
std::function<double(void)> VibeBenchComponentsPCMPrepare(NSString *name, double outputRate = 0);

// A fresh directory, removed when the process exits.
NSString *VibeBenchComponentsTemporaryDirectory(NSString *label);
// Runs the main queue, where metadata deliveries land, until done or a
// generous bound; running out fails the benchmark.
void VibeBenchComponentsSpinMainUntil(BOOL (^done)(void));
// `count` samples of white noise at half scale from a seeded LCG, the same
// for a seed in every build: what the resample and pitch benchmarks convert.
void VibeBenchComponentsNoise(float *samples, size_t count, uint32_t seed);
// `count` one-byte files in folders of 100, the relative paths returned.
NSArray<NSString *> *VibeBenchComponentsMakeFiles(NSString *root, NSUInteger count, NSString *extension);

// Pushes the default theme's fonts into Fonts' slots once, as the shell pushes
// the theme's before any label exists. Unpushed, a slot draws the fallback
// face at the system size. A benchmark that draws text calls it in prepare.
// Only those do, because loading the fonts changes later rows' costs.
void VibeBenchComponentsPushThemeFonts(void);

// With VIBE_BENCH_COMPONENTS_UI_DUMP set to a directory, writes what a UI
// benchmark's subject draws there, so two builds' pictures can be compared
// byte for byte.
void VibeBenchComponentsUIDump(NSString *name, NSData *bytes);

// A layer's picture as its pixels, empty without one.
@class CALayer;
NSData *VibeBenchComponentsUIContents(CALayer *layer);

#if VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY
#include "WaveformSummary.hpp"
#include <memory>
// A summary of the mix alone, as Vibe keeps it, in whichever shape the
// version's builder takes, and a block of the mix into it.
static inline std::unique_ptr<wavecore::SummaryBuilder> VibeBenchComponentsMixBuilder(bool bands, int64_t frames,
                                                                                       double rate) {
#if VIBE_BENCH_COMPONENTS_WAVEFORM_MIX_ONLY
    return std::make_unique<wavecore::SummaryBuilder>(bands, frames, rate);
#else
    return std::make_unique<wavecore::SummaryBuilder>(1, 1, bands, frames, rate);
#endif
}
static inline void VibeBenchComponentsAppendMix(wavecore::SummaryBuilder &builder, const float *mono, size_t frames) {
#if VIBE_BENCH_COMPONENTS_WAVEFORM_MIX_ONLY
    builder.append(mono, frames);
#else
    builder.append(mono, mono, frames);
#endif
}
#endif

// --analyze: every audio file under `root` through the waveform loader with
// both analyzers, one "path<TAB>bpm<TAB>key" line each, in path order, so two
// builds' answers can be diffed for exactness. Registered by the file that
// implements it, so a version without that file still builds.
typedef int (*VibeBenchComponentsAnalyzeTreeFunction)(NSString *root);
void VibeBenchComponentsSetAnalyzeTree(VibeBenchComponentsAnalyzeTreeFunction function);

// --waveform: one file through the waveform loader and a renderer, drawn as
// the iOS scrubber lays it out (the vibe-waveform skill). Takes the
// arguments after the file. Registered as --analyze is.
typedef int (*VibeBenchComponentsWaveformProbeFunction)(NSString *path, int argc, const char *argv[]);
void VibeBenchComponentsSetWaveformProbe(VibeBenchComponentsWaveformProbeFunction function);
