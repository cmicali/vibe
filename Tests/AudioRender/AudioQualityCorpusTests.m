//
//  AudioQualityCorpusTests.m
//  VibeAudioTests
//
//  A downloaded test corpus, every playable file in it run through the
//  handle. The vibe-audio-quality skill's script fetches the corpus and names
//  it in VIBE_AUDIO_QUALITY_CORPUS. Without one the test skips, so no default
//  run reads a corpus.
//
//  A file the corpus says is valid must decode right: one with a reference
//  decode beside it, or a FLAC whose path matches VIBE_AUDIO_QUALITY_MD5 and
//  whose STREAMINFO carries an MD5. It must open, match the reference or the
//  MD5, decode to the length the handle states, and seek exactly. Every other
//  file must only finish without a hang and without a sample that is not
//  finite. One that opens and then misbehaves is a warning.
//

#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>
#import "AudioFileHandle.h"
#import "AudioFileHandleInternal.h"
#import "PlayableExtensions.h"

// Layer III's synthesis delay: a reference decode keeps it, and the handle
// drops it from the start.
static const AVAudioFramePosition kLayer3Delay = 529;
static const AVAudioFrameCount kChunk = 65536, kProbe = 1024;
static const NSTimeInterval kFileDeadline = 300;

@interface AudioQualityCorpusTests : XCTestCase
@end

// A reference decode beside the file, as interleaved float: `<file>.ref.f32`
// (float32), `<file>.ref.s16` (16-bit) or `<file>.ref.wav`. `bits` is its
// precision. nil for none.
static NSData *VibeReference(NSURL *url, UInt32 *bits) {
    NSData *f32 = [NSData dataWithContentsOfFile:[url.path stringByAppendingString:@".ref.f32"]];
    if (f32) {
        *bits = 32;
        return f32;
    }
    NSData *s16 = [NSData dataWithContentsOfFile:[url.path stringByAppendingString:@".ref.s16"]];
    if (s16) {
        NSMutableData *samples = [NSMutableData dataWithLength:s16.length / 2 * sizeof(float)];
        const int16_t *in = s16.bytes;
        float *out = samples.mutableBytes;
        for (NSUInteger i = 0; i < s16.length / 2; i++) out[i] = (float)(int16_t)OSSwapLittleToHostInt16(in[i]) / 32768;
        *bits = 16;
        return samples;
    }
    NSURL *wav = [NSURL fileURLWithPath:[url.path stringByAppendingString:@".ref.wav"]];
    AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:wav interleaved:YES error:NULL];
    if (!file) {
        return nil;
    }
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:kChunk];
    NSMutableData *samples = [NSMutableData data];
    while ([file readIntoBuffer:buffer error:NULL] && buffer.frameLength > 0) {
        [samples appendBytes:buffer.floatChannelData[0] length:buffer.frameLength * file.processingFormat.channelCount * sizeof(float)];
    }
    *bits = file.fileFormat.streamDescription->mBitsPerChannel;
    return samples;
}

// A FLAC's STREAMINFO: its sample size, and the MD5 of its samples when the
// encoder wrote one.
typedef struct {
    UInt32 bits;
    BOOL hasMD5;
    uint8_t md5[CC_MD5_DIGEST_LENGTH];
} VibeFLACInfo;

static VibeFLACInfo VibeFLACInfoOf(NSURL *url) {
    VibeFLACInfo info = {0};
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
    NSData *head = [handle readDataUpToLength:64 * 1024 error:NULL];
    const uint8_t *b = head.bytes;
    uint64_t at = 0;
    while (head.length >= at + 10 && VibeID3v2TagBytes(b + at)) {
        at += VibeID3v2TagBytes(b + at);
    }
    if (at != 0) {
        [handle seekToOffset:at error:NULL];
        head = [handle readDataUpToLength:64 * 1024 error:NULL];
        b = head.bytes;
    }
    if (head.length < 42 || memcmp(b, "fLaC", 4) != 0 || (b[4] & 0x7F) != 0) {
        return info;
    }
    const uint8_t *streaminfo = b + 8;
    info.bits = (UInt32)(((streaminfo[12] & 1) << 4) | (streaminfo[13] >> 4)) + 1;
    memcpy(info.md5, streaminfo + 18, sizeof info.md5);
    for (size_t i = 0; i < sizeof info.md5; i++) info.hasMD5 |= info.md5[i] != 0;
    return info;
}

// Our frame i against the reference's i + shift, over the frames both hold
// but the last `tail`: the RMS and largest difference, and how many frames.
// `top` clips our samples to what an integer reference can hold, 0 for none.
static AVAudioFramePosition VibeDifference(NSData *ours, NSData *theirs, UInt32 channels, AVAudioFramePosition shift,
                                           AVAudioFramePosition tail, double top, double *rms, double *worst) {
    const float *a = ours.bytes, *b = theirs.bytes;
    AVAudioFramePosition first = MAX(0, -shift);
    AVAudioFramePosition last = MIN((AVAudioFramePosition)(ours.length / sizeof(float) / channels),
                                    (AVAudioFramePosition)(theirs.length / sizeof(float) / channels) - shift) - tail;
    double sum = 0, max = 0;
    for (AVAudioFramePosition i = first * channels; i < last * channels; i++) {
        double sample = top > 0 ? fmin(fmax(a[i], -1), top) : a[i];
        double difference = sample - b[i + shift * channels];
        sum += difference * difference;
        max = fmax(max, fabs(difference));
    }
    *rms = last > first ? sqrt(sum / (double)((last - first) * channels)) : INFINITY;
    *worst = max;
    return MAX(last - first, 0);
}

// One file's checks, as a record for the results file. `md5` says whether
// the file's FLAC MD5 counts. A file whose reference check fails leaves its
// decode in `keep`, as interleaved float32.
static NSDictionary *VibeCheck(NSURL *url, NSString *name, BOOL md5Counts, NSString *keep) {
    NSMutableArray<NSString *> *failures = [NSMutableArray array], *warnings = [NSMutableArray array];
    NSMutableDictionary *record = [@{@"file": name, @"failures": failures, @"warnings": warnings} mutableCopy];
    UInt32 referenceBits = 0;
    NSData *reference = VibeReference(url, &referenceBits);
    VibeFLACInfo flac = md5Counts && [url.pathExtension.lowercaseString isEqualToString:@"flac"] ? VibeFLACInfoOf(url)
                                                                                               : (VibeFLACInfo){0};
    BOOL valid = reference || flac.hasMD5;
    NSMutableArray<NSString *> *strict = valid ? failures : warnings;
    record[@"valid"] = @(valid);

    NSError *error = nil;
    AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:url error:&error];
    if (!file) {
        record[@"outcome"] = @"refused";
        record[@"error"] = error.localizedDescription ?: @"";
        if (valid) {
            [failures addObject:@"refused"];
        }
        return record;
    }
    UInt32 channels = file.processingFormat.channelCount;
    BOOL estimated = NO;
    AVAudioFramePosition length = [file lengthEstimated:&estimated];
    record[@"decoder"] = file.decoderName;
    record[@"rate"] = @(file.processingFormat.sampleRate);
    record[@"channels"] = @(channels);
    record[@"length"] = @(length);

    // Where a seek lands is checked against the continuous decode. Apple's
    // decoders are not held to exact seeks.
    BOOL seeks = ![file.decoderName isEqualToString:@"apple"] && !estimated && length > 8 * kProbe;
    AVAudioFramePosition probes[4];
    NSMutableData *heard[4];
    for (int k = 0; k < 4; k++) {
        probes[k] = length * (k + 1) / 5;
        heard[k] = [NSMutableData dataWithLength:kProbe * channels * sizeof(float)];
    }
    BOOL md5 = flac.hasMD5 && flac.bits <= 24 && [file.decoderName isEqualToString:@"dr_flac"];
    CC_MD5_CTX context;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations" // a checksum the file states, not security
    CC_MD5_Init(&context);
#pragma clang diagnostic pop
    const double scale = md5 ? ldexp(1, (int)flac.bits - 1) : 0;
    const UInt32 sampleBytes = (flac.bits + 7) / 8;
    NSMutableData *decoded = reference ? [NSMutableData data] : nil;
    NSMutableData *interleaved = [NSMutableData dataWithLength:kChunk * channels * sizeof(float)];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:kChunk];
    AVAudioFramePosition frames = 0;
    BOOL finite = YES;
    while (YES) {
        if (![file readIntoBuffer:buffer error:&error]) {
            [strict addObject:[NSString stringWithFormat:@"read failed at frame %lld: %@", frames, error.localizedDescription]];
            break;
        }
        AVAudioFrameCount got = buffer.frameLength;
        if (got == 0) {
            break;
        }
        float *samples = interleaved.mutableBytes;
        for (AVAudioFrameCount f = 0; f < got; f++) {
            for (UInt32 c = 0; c < channels; c++) {
                float sample = buffer.floatChannelData[c][f];
                finite &= isfinite(sample);
                samples[f * channels + c] = sample;
            }
        }
        if (md5) {
            uint8_t bytes[4 * 8 * 4096];
            for (AVAudioFrameCount f = 0; f < got;) {
                AVAudioFrameCount run = MIN(got - f, (AVAudioFrameCount)(sizeof bytes / (sampleBytes * channels)));
                size_t at = 0;
                for (AVAudioFrameCount i = 0; i < run * channels; i++) {
                    int32_t value = (int32_t)lrint(samples[f * channels + i] * scale);
                    for (UInt32 byte = 0; byte < sampleBytes; byte++) bytes[at++] = (uint8_t)(value >> (8 * byte));
                }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                CC_MD5_Update(&context, bytes, (CC_LONG)at);
#pragma clang diagnostic pop
                f += run;
            }
        }
        [decoded appendBytes:samples length:got * channels * sizeof(float)];
        for (int k = 0; seeks && k < 4; k++) {
            AVAudioFramePosition from = MAX(probes[k], frames), to = MIN(probes[k] + kProbe, frames + got);
            if (from < to) {
                memcpy((float *)heard[k].mutableBytes + (from - probes[k]) * channels, samples + (from - frames) * channels,
                       (size_t)(to - from) * channels * sizeof(float));
            }
        }
        frames += got;
    }
    record[@"outcome"] = @"decoded";
    record[@"frames"] = @(frames);
    if (!finite) {
        [failures addObject:@"a sample that is not finite"];
    }
    if (!estimated && frames != length) {
        [strict addObject:[NSString stringWithFormat:@"length %lld, decoded %lld", length, frames]];
    }
    if (md5) {
        uint8_t digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CC_MD5_Final(digest, &context);
#pragma clang diagnostic pop
        BOOL same = memcmp(digest, flac.md5, sizeof digest) == 0;
        record[@"md5"] = same ? @"pass" : @"fail";
        if (!same) {
            [strict addObject:@"MD5 differs from STREAMINFO's"];
        }
    }
    BOOL seeksExact = YES;
    for (int k = 0; seeks && seeksExact && k < 4 && frames >= probes[k] + kProbe; k++) {
        AudioFileHandle *again = [[AudioFileHandle alloc] initForReading:url error:NULL];
        AVAudioPCMBuffer *slice = [[AVAudioPCMBuffer alloc] initWithPCMFormat:again.processingFormat frameCapacity:kProbe];
        BOOL same = again && [again seekToFrame:probes[k] error:NULL] && [again readIntoBuffer:slice error:NULL]
                && slice.frameLength == kProbe;
        const float *expected = heard[k].bytes;
        for (AVAudioFrameCount f = 0; same && f < kProbe; f++) {
            for (UInt32 c = 0; c < channels; c++) same &= slice.floatChannelData[c][f] == expected[f * channels + c];
        }
        if (!same) {
            [strict addObject:[NSString stringWithFormat:@"a seek to frame %lld differs from the continuous decode", probes[k]]];
            seeksExact = NO;
        }
    }
    record[@"seeks"] = seeks ? @(seeksExact) : [NSNull null];
    if (reference) {
        // An MPEG reference keeps the synthesis delay at its start, and its
        // last frames come from a final packet the parser does not serve.
        // ISO's decoder also leaves out leading frames it cannot decode, whose
        // bit reservoir starts before the file. Vibe keeps them as silence.
        // So up to two left out are tried, and the closest kept. A wrong
        // alignment misses by far more than any decoder error.
        BOOL mpeg = [file.decoderName isEqualToString:@"dr_mp3"];
        AVAudioFramePosition referenceFrames = (AVAudioFramePosition)(reference.length / sizeof(float) / channels);
        double top = referenceBits <= 24 ? 1 - ldexp(1, 1 - (int)referenceBits) : 0; // an integer reference clips overs
        AVAudioFramePosition skipped = 0, compared = 0;
        double rms = INFINITY, worst = INFINITY;
        for (AVAudioFramePosition left = 0; left <= (mpeg ? 2 : 0); left++) {
            double r = INFINITY, w = INFINITY;
            AVAudioFramePosition count = VibeDifference(decoded, reference, channels, mpeg ? kLayer3Delay - left * 1152 : 0,
                                                        mpeg ? kLayer3Delay : 0, top, &r, &w);
            if (r < rms) {
                rms = r;
                worst = w;
                skipped = left;
                compared = count;
            }
        }
        if (compared <= 0) {
            [failures addObject:[NSString stringWithFormat:@"reference: %lld frames, none in common with the %lld decoded",
                                 referenceFrames, frames]];
            return record;
        }
        // ISO/IEC 11172-4: full accuracy against a reference of 24 bits or
        // more, limited accuracy against one rounded to 16.
        BOOL full = referenceBits >= 24;
        BOOL pass = full ? rms < 1.0 / 32768 / sqrt(12) && worst <= 1.0 / 16384 : rms < 1.0 / 2048 / sqrt(12);
        record[@"reference"] = @{@"bits": @(referenceBits), @"rms": @(rms), @"max": @(worst), @"frames": @(compared),
                                 @"leftOut": @(skipped), @"pass": @(pass), @"criterion": full ? @"full accuracy" : @"limited accuracy"};
        if (!pass) {
            [decoded writeToFile:keep atomically:YES];
            [strict addObject:[NSString stringWithFormat:@"reference: RMS %.3g, max %.3g (%@)", rms, worst,
                               full ? @"full accuracy" : @"limited accuracy"]];
        }
    }
    return record;
}

@implementation AudioQualityCorpusTests

- (void)testCorpus {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *root = environment[@"VIBE_AUDIO_QUALITY_CORPUS"], *results = environment[@"VIBE_AUDIO_QUALITY_RESULTS"];
    XCTSkipUnless(root.length > 0 && results.length > 0, @"Run from the vibe-audio-quality skill, which names a corpus");
    NSString *pattern = environment[@"VIBE_AUDIO_QUALITY_MD5"];
    NSRegularExpression *md5 = pattern.length ? [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL] : nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *path in [NSFileManager.defaultManager enumeratorAtPath:root]) {
        // A reference decode beside a file is no file to check.
        if ([PlayableExtensions.lookup containsObject:path.pathExtension.lowercaseString] && ![path containsString:@".ref."]) {
            [names addObject:path];
        }
    }
    [names sortUsingSelector:@selector(compare:)];
    XCTAssertGreaterThan(names.count, 0u, @"%@ holds no playable file", root);

    // The file in progress, so the script can name the one that crashed the run.
    NSString *current = [results stringByAppendingString:@".current"];
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSString *name in names) {
        [name writeToFile:current atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        __block NSDictionary *record = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_queue_create("corpus.file", DISPATCH_QUEUE_SERIAL), ^{
            @autoreleasepool {
                NSString *keep = [[results stringByDeletingPathExtension] stringByAppendingPathComponent:
                        [name stringByAppendingString:@".decoded.f32"]];
                [NSFileManager.defaultManager createDirectoryAtPath:keep.stringByDeletingLastPathComponent
                                        withIntermediateDirectories:YES attributes:nil error:NULL];
                BOOL md5Counts = md5 && [md5 firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
                record = VibeCheck([NSURL fileURLWithPath:[root stringByAppendingPathComponent:name]], name, md5Counts, keep);
            }
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFileDeadline * NSEC_PER_SEC))) != 0) {
            record = @{@"file": name, @"outcome": @"hang", @"failures": @[@"did not finish"], @"warnings": @[]};
        }
        [records addObject:record];
    }
    [NSFileManager.defaultManager removeItemAtPath:current error:NULL];
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"corpus": root, @"files": records}
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    XCTAssertTrue([json writeToFile:results atomically:YES], @"%@", results);

    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    for (NSDictionary *record in records) {
        NSArray *failures = record[@"failures"];
        if (failures.count) [failed addObject:[NSString stringWithFormat:@"%@: %@", record[@"file"], [failures componentsJoinedByString:@"; "]]];
    }
    XCTAssertEqual(failed.count, 0u, @"%lu of %lu files failed:\n%@", (unsigned long)failed.count, (unsigned long)records.count,
                   [[failed subarrayWithRange:NSMakeRange(0, MIN(failed.count, 40u))] componentsJoinedByString:@"\n"]);
}

@end
