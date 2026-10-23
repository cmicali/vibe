//
//  DebugBPMScan.mm
//  Vibe
//

#import "DebugCommonVerbs.h"

#if DEBUG

#import <AVFAudio/AVFAudio.h>
#import "AudioAnalysisObservers.h"
#import "AudioFileHandle.h"
#import "AudioWaveform.h"
#import "MusicalKey.h"

#include <vector>

// See DebugCommonVerbs.h for the contract. The decode mirrors the waveform loader's
// — interleaved float32 through the shared mono mix, into the observer's own
// sink — so the result is what an in-app load would detect.

static NSString *VibeScanJSONForDictionary(NSDictionary *reply) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// The whole file through one sink of `observer`, finished. Returns nil on
// success or the error-reply JSON. The timing splits decode from analysis, so
// one pass reports both accuracy and cost.
static NSString *VibeScanDecode(NSString *rawPath, AudioWaveformObserver *observer,
                                id<AudioWaveformSink> __strong *outSink, NSNumber *__strong *outResult,
                                NSDictionary *__strong *outTiming) {
    NSString *path = rawPath.stringByExpandingTildeInPath;
    NSError *error = nil;
    AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:[NSURL fileURLWithPath:path]
                                                interleaved:YES
                                                      error:&error];
    NSUInteger numChannels = file.processingFormat.channelCount;
    if (!file || file.length <= 0 || numChannels == 0) {
        return VibeScanJSONForDictionary(@{
            @"error": [NSString stringWithFormat:@"could not open %@: %@",
                       path, error.localizedDescription ?: @"no audio"],
        });
    }
    double sampleRate = file.processingFormat.sampleRate;
    id<AudioWaveformSink> sink = [observer sinkForSampleRate:sampleRate window:NSMakeRange(0, (NSUInteger)file.length)];
    uint64_t decodeNanos = 0, appendNanos = 0;
    AVAudioFramePosition frames = 0;

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
    while (file.framePosition < file.length) {
        uint64_t phaseStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (![file readIntoBuffer:buffer error:&error]) {
            return VibeScanJSONForDictionary(@{
                @"error": [NSString stringWithFormat:@"read failed at frame %lld: %@",
                           file.framePosition, error.localizedDescription ?: @"unknown"],
            });
        }
        if (buffer.frameLength == 0) {
            break; // a truncated file must not spin forever
        }
        const float *mono = AudioWaveformMonoMix(buffer.floatChannelData[0], monoScratch.data(),
                                                 buffer.frameLength, numChannels);
        decodeNanos += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - phaseStart;
        phaseStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        [sink appendMonoSamples:mono frameCount:buffer.frameLength];
        appendNanos += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - phaseStart;
        frames += buffer.frameLength;
    }
    uint64_t finishStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    *outResult = [sink waveformResult];
    uint64_t finishNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - finishStart;
    // decodeSeconds here includes the mono downmix, which dump_timing's
    // in-app entries count under chunkSeconds instead: the two reports agree
    // on the total, not bucket by bucket.
    double (^seconds)(uint64_t) = ^double(uint64_t nanos) { return (double)nanos / NSEC_PER_SEC; };
    *outSink = sink;
    *outTiming = @{
        @"audioSeconds": @(sampleRate > 0 ? (double)frames / sampleRate : 0),
        @"decodeSeconds": @(seconds(decodeNanos)),
        @"analyzeSeconds": @(seconds(appendNanos + finishNanos)),
        @"streamSeconds": @(seconds(appendNanos)),
        @"finishSeconds": @(seconds(finishNanos)),
    };
    return nil;
}

NSString *VibeDebugBPMScanJSON(NSString *rawPath) {
    @autoreleasepool {
        id<AudioWaveformSink> sink = nil;
        NSNumber *bpm = nil;
        NSDictionary *timing = nil;
        NSString *errorJSON = VibeScanDecode(rawPath, AudioBPMAnalyzer.waveformObserver, &sink, &bpm, &timing);
        if (errorJSON) {
            return errorJSON;
        }
        return VibeScanJSONForDictionary(@{
            @"ok": @YES,
            @"bpm": bpm,
            @"timing": timing,
        });
    }
}

NSString *VibeDebugKeyScanJSON(NSString *rawPath) {
    @autoreleasepool {
        id<AudioWaveformSink> sink = nil;
        NSNumber *result = nil;
        NSDictionary *timing = nil;
        NSString *errorJSON = VibeScanDecode(rawPath, AudioKeyAnalyzer.waveformObserver, &sink, &result, &timing);
        if (errorJSON) {
            return errorJSON;
        }
        VibeMusicalKey key = result.integerValue;
        return VibeScanJSONForDictionary(@{
            @"ok": @YES,
            @"key": VibeMusicalKeyMusicalName(key),
            @"camelot": VibeMusicalKeyCamelotName(key),
            @"index": @(key),
            @"tuningCents": @(((AudioKeyAnalyzer *)sink).tuningCents),
            @"timing": timing,
        });
    }
}

#endif
