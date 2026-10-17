//
//  AudioWaveform.mm
//  Vibe
//

#import "AudioWaveform.h"

#include <vector>

// See the declaration in AudioWaveform.h.
const int kCodableAudioWaveformVersion = 6;

@implementation CodableAudioWaveform {
    std::unique_ptr<AudioWaveform> _waveform;
}

- (instancetype)initWithWaveform:(std::unique_ptr<AudioWaveform>)waveform {
    self = [super init];
    if (self) {
        _waveform = std::move(waveform);
        self.key = -1; // 0 is C major; see the property comment
    }
    return self;
}

- (AudioWaveform *)waveform {
    return _waveform.get();
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInt:kCodableAudioWaveformVersion forKey:@"version"];
    std::vector<uint8_t> summary = _waveform ? _waveform->encode() : std::vector<uint8_t>();
    [coder encodeBytes:summary.data() length:summary.size() forKey:@"summary"];
    [coder encodeFloat:self.bpm forKey:@"bpm"];
    // As an object, not encodeInteger: an absent integer decodes as 0, which
    // as a key means C major, whereas an absent object is unambiguously nil.
    [coder encodeObject:@(self.key) forKey:@"key"];
    [coder encodeBool:self.bpmAnalyzed forKey:@"bpmAnalyzed"];
    [coder encodeBool:self.keyAnalyzed forKey:@"keyAnalyzed"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        // A missing or mismatched version, or a malformed payload, is
        // rejected; the waveform regenerates.
        if ([coder decodeIntForKey:@"version"] != kCodableAudioWaveformVersion) {
            return nil;
        }
        NSUInteger length = 0;
        const uint8_t *bytes = [coder decodeBytesForKey:@"summary" returnedLength:&length];
        // decode validates every field and value, and refuses non-finite
        // ones: the archive has no checksum, so a bit-rotted entry would
        // otherwise poison every view's geometry until it aged out. Only a
        // complete waveform is ever filed.
        _waveform = AudioWaveform::decode(bytes, length);
        if (!_waveform || !_waveform->isComplete()) {
            return nil;
        }
        float bpm = [coder decodeFloatForKey:@"bpm"];
        self.bpm = std::isfinite(bpm) && bpm > 0 ? bpm : 0;
        // Like bpm, a bad key degrades to "unknown" rather than rejecting the
        // entry — it is not a reason to throw away good waveform data. Absent
        // decodes nil, and nil falls to -1, never C major.
        id keyValue = [coder decodeObjectForKey:@"key"];
        NSInteger key = [keyValue isKindOfClass:[NSNumber class]] ? [keyValue integerValue] : -1;
        self.key = (key >= 0 && key < 24) ? key : -1;
        self.bpmAnalyzed = ![coder containsValueForKey:@"bpmAnalyzed"] || [coder decodeBoolForKey:@"bpmAnalyzed"];
        self.keyAnalyzed = ![coder containsValueForKey:@"keyAnalyzed"] || [coder decodeBoolForKey:@"keyAnalyzed"];
    }
    return self;
}

@end
