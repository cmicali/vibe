//
//  DebugBPMScan.mm
//  Vibe
//

#import "DebugUtil.h"

#if DEBUG

#import <AVFAudio/AVFAudio.h>
#import "AudioBPMAnalyzer.h"
#import "AudioKeyAnalyzer.h"
#import "AudioWaveform.h"
#import "AudioLoadTiming.h"
#import "MusicalKey.h"

#include <vector>

// The core of the `scan_bpm` and `scan_key` debug commands. Each decodes the
// file and runs its analyzer in the calling process, returning one JSON
// object. The decode mirrors the waveform loader's — interleaved float32,
// with the shared mono mix — so the result is exactly what an in-app load
// would detect.
//
// They touch no app state and no caches, which is why the debug CLI client in
// DebugClient.m runs these verbs locally rather than doing the channel
// round-trip: they work with no app running. The same functions back the
// app-side table entries for any caller that posts the command file directly.
//
// Sandbox note: whichever process runs this is sandboxed, so <file> must sit
// somewhere it can read, in practice the app container's tmp. The clients'
// stdin forms (`scan_bpm -`, `scan_key -`) stage the bytes there; see
// scan-bpm.sh and scan-key.sh.

static NSString *VibeScanJSONForDictionary(NSDictionary *reply) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Decodes the whole file, feeding each buffer's shared mono mix to `consume`,
// and returns nil on success or the error-reply JSON. The two nanosecond
// counters split the decode from the analyzer work, so a validation run can
// report both accuracy and cost from one pass.
static NSString *VibeScanDecode(NSString *rawPath, double *outSampleRate,
                                uint64_t *outDecodeNanos, uint64_t *outAnalyzeNanos,
                                void (^prepare)(double sampleRate),
                                void (^consume)(const float *mono, NSUInteger frameCount)) {
    NSString *path = rawPath.stringByExpandingTildeInPath;
    NSError *error = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path]
                                               commonFormat:AVAudioPCMFormatFloat32
                                                interleaved:YES
                                                      error:&error];
    NSUInteger numChannels = file.processingFormat.channelCount;
    if (!file || file.length <= 0 || numChannels == 0) {
        return VibeScanJSONForDictionary(@{
            @"error": [NSString stringWithFormat:@"could not open %@: %@",
                       path, error.localizedDescription ?: @"no audio"],
        });
    }
    *outSampleRate = file.processingFormat.sampleRate;
    prepare(*outSampleRate);

    const AVAudioFrameCount kBlockFrames = 65536;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                             frameCapacity:kBlockFrames];
    if (!buffer) {
        return VibeScanJSONForDictionary(@{@"error": @"could not allocate PCM buffer"});
    }
    std::vector<float> monoScratch;
    if (numChannels > 1) {
        monoScratch.resize(kBlockFrames);
    }
    // Bounded by framePosition rather than reading until empty. A read
    // issued exactly at EOF does not report a clean zero-length success:
    // it fails with a nil error, an AVAudioFile quirk. So never issue it.
    while (file.framePosition < file.length) {
        uint64_t phaseStart = VibeLoadClockNow();
        if (![file readIntoBuffer:buffer error:&error]) {
            return VibeScanJSONForDictionary(@{
                @"error": [NSString stringWithFormat:@"read failed at frame %lld: %@",
                           file.framePosition, error.localizedDescription ?: @"unknown"],
            });
        }
        if (buffer.frameLength == 0) {
            break; // defensive: a truncated file must not spin forever
        }
        const float *mono = AudioWaveformMonoMix(buffer.floatChannelData[0], monoScratch.data(),
                                                 buffer.frameLength, numChannels);
        *outDecodeNanos += VibeLoadClockNow() - phaseStart;
        phaseStart = VibeLoadClockNow();
        consume(mono, buffer.frameLength);
        *outAnalyzeNanos += VibeLoadClockNow() - phaseStart;
    }
    return nil;
}

// The shared reply tail: the phase split plus the audio length it covers.
// decodeSeconds here includes the mono downmix, which dump_timing's in-app
// entries count under chunkSeconds instead — the two reports agree on the
// total, not bucket by bucket.
static NSDictionary *VibeScanTiming(double sampleRate, AVAudioFramePosition frames,
                                    uint64_t decodeNanos, uint64_t analyzeNanos, uint64_t finishNanos) {
    double (^seconds)(uint64_t) = ^double(uint64_t nanos) { return (double)nanos / NSEC_PER_SEC; };
    return @{
        @"audioSeconds": @(sampleRate > 0 ? (double)frames / sampleRate : 0),
        @"decodeSeconds": @(seconds(decodeNanos)),
        @"analyzeSeconds": @(seconds(analyzeNanos + finishNanos)),
        @"streamSeconds": @(seconds(analyzeNanos)),
        @"finishSeconds": @(seconds(finishNanos)),
    };
}

NSString *VibeDebugBPMScanJSON(NSString *rawPath) {
    @autoreleasepool {
        __block AudioBPMAnalyzer *analyzer = nil;
        double sampleRate = 0;
        uint64_t decodeNanos = 0, analyzeNanos = 0;
        __block AVAudioFramePosition frames = 0;
        NSString *errorJSON = VibeScanDecode(rawPath, &sampleRate, &decodeNanos, &analyzeNanos,
                ^(double sr) {
                    analyzer = [[AudioBPMAnalyzer alloc] initWithSampleRate:sr];
                },
                ^(const float *mono, NSUInteger frameCount) {
                    frames += (AVAudioFramePosition)frameCount;
                    [analyzer appendMonoSamples:mono frameCount:frameCount];
                });
        if (errorJSON) {
            return errorJSON;
        }
        uint64_t finishStart = VibeLoadClockNow();
        float bpm = [analyzer finish];
        uint64_t finishNanos = VibeLoadClockNow() - finishStart;
        return VibeScanJSONForDictionary(@{
            @"ok": @YES,
            @"bpm": @(bpm),
            @"timing": VibeScanTiming(sampleRate, frames, decodeNanos, analyzeNanos, finishNanos),
        });
    }
}

NSString *VibeDebugKeyScanJSON(NSString *rawPath) {
    @autoreleasepool {
        __block AudioKeyAnalyzer *analyzer = nil;
        double sampleRate = 0;
        uint64_t decodeNanos = 0, analyzeNanos = 0;
        __block AVAudioFramePosition frames = 0;
        NSString *errorJSON = VibeScanDecode(rawPath, &sampleRate, &decodeNanos, &analyzeNanos,
                ^(double sr) {
                    analyzer = [[AudioKeyAnalyzer alloc] initWithSampleRate:sr];
                },
                ^(const float *mono, NSUInteger frameCount) {
                    frames += (AVAudioFramePosition)frameCount;
                    [analyzer appendMonoSamples:mono frameCount:frameCount];
                });
        if (errorJSON) {
            return errorJSON;
        }
        uint64_t finishStart = VibeLoadClockNow();
        VibeMusicalKey key = [analyzer finish];
        uint64_t finishNanos = VibeLoadClockNow() - finishStart;
        // Empty strings and index -1 mean no confident key, mirroring
        // scan_bpm's bpm 0.
        return VibeScanJSONForDictionary(@{
            @"ok": @YES,
            @"key": VibeMusicalKeyMusicalName(key),
            @"camelot": VibeMusicalKeyCamelotName(key),
            @"index": @(key),
            @"tuningCents": @(analyzer.tuningCents),
            @"timing": VibeScanTiming(sampleRate, frames, decodeNanos, analyzeNanos, finishNanos),
        });
    }
}

#endif
