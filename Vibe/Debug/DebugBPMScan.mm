//
// Created by Christopher Micali on 7/19/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "DebugUtil.h"

#if DEBUG

#import <AVFAudio/AVFAudio.h>
#import "AudioBPMAnalyzer.h"
#import "AudioWaveform.h"

#include <vector>

// Core of the `scan_bpm` debug command: decodes the file and runs
// AudioBPMAnalyzer in the CALLING process, returning one JSON object. The
// decode mirrors the waveform loader's (interleaved float32, shared mono mix)
// so the result is exactly what an in-app load would detect. No app state, no
// caches — which is why the debug CLI client executes this verb locally
// (DebugUtil.m) instead of doing the channel round-trip: it works with no app
// running. The same function backs the app-side table entry for any caller
// that posts the command file directly.
//
// Sandbox: whichever process runs this is sandboxed, so <file> must be
// somewhere it can read — in practice the app container's tmp (the client's
// `scan_bpm -` stdin form stages the bytes there; see scan-bpm.sh).

static NSString *VibeBPMScanJSONForDictionary(NSDictionary *reply) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

NSString *VibeDebugBPMScanJSON(NSString *rawPath) {
    @autoreleasepool {
        NSString *path = rawPath.stringByExpandingTildeInPath;
        NSError *error = nil;
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path]
                                                   commonFormat:AVAudioPCMFormatFloat32
                                                    interleaved:YES
                                                          error:&error];
        NSUInteger numChannels = file.processingFormat.channelCount;
        if (!file || file.length <= 0 || numChannels == 0) {
            return VibeBPMScanJSONForDictionary(@{
                @"error": [NSString stringWithFormat:@"could not open %@: %@",
                           path, error.localizedDescription ?: @"no audio"],
            });
        }

        const AVAudioFrameCount kBlockFrames = 65536;
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                                 frameCapacity:kBlockFrames];
        if (!buffer) {
            return VibeBPMScanJSONForDictionary(@{@"error": @"could not allocate PCM buffer"});
        }
        AudioBPMAnalyzer *analyzer =
                [[AudioBPMAnalyzer alloc] initWithSampleRate:file.processingFormat.sampleRate];
        std::vector<float> monoScratch;
        if (numChannels > 1) {
            monoScratch.resize(kBlockFrames);
        }
        // Bounded by framePosition, not read-until-empty: a read issued exactly
        // at EOF doesn't report a clean zero-length success — it fails with a
        // nil error (AVAudioFile quirk, verified) — so never issue it.
        while (file.framePosition < file.length) {
            if (![file readIntoBuffer:buffer error:&error]) {
                return VibeBPMScanJSONForDictionary(@{
                    @"error": [NSString stringWithFormat:@"read failed at frame %lld: %@",
                               file.framePosition, error.localizedDescription ?: @"unknown"],
                });
            }
            if (buffer.frameLength == 0) {
                break; // defensive: a truncated file must not spin forever
            }
            const float *mono = AudioWaveformMonoMix(buffer.floatChannelData[0], monoScratch.data(),
                                                     buffer.frameLength, numChannels);
            [analyzer appendMonoSamples:mono frameCount:buffer.frameLength];
        }

        float bpm = [analyzer finish];
        return VibeBPMScanJSONForDictionary(@{@"ok": @YES, @"bpm": @(bpm)});
    }
}

#endif
