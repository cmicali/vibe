//
//  AudioWaveform.mm
//  Vibe
//

#import "AudioWaveform.h"
#import "AudioWaveformObserver.h"

#include <cmath>
#include <cstring>
#include <vector>

// See the declaration in AudioWaveform.h.
const int kCodableAudioWaveformVersion = 6;

// Beside each result, whether the decode ran its observer.
static NSString *VibeRanKey(NSString *identifier) {
    return [identifier stringByAppendingString:@"Analyzed"];
}

@implementation CodableAudioWaveform {
    std::unique_ptr<AudioWaveform> _waveform;
}

- (instancetype)initWithWaveform:(std::unique_ptr<AudioWaveform>)waveform {
    self = [super init];
    if (self) {
        _waveform = std::move(waveform);
        _results = @{};
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
    // Format 6's own shapes: a floating result inline, as the tempo always
    // was, and any other as an object, as the key always was. An absent
    // object decodes as nil, never as a 0 that could pass for a result.
    [self.results enumerateKeysAndObjectsUsingBlock:^(NSString *identifier, NSNumber *result, BOOL *stop) {
        const char *type = result.objCType;
        if (strcmp(type, @encode(float)) == 0) {
            [coder encodeFloat:result.floatValue forKey:identifier];
        }
        else if (strcmp(type, @encode(double)) == 0) {
            [coder encodeDouble:result.doubleValue forKey:identifier];
        }
        else {
            [coder encodeObject:result forKey:identifier];
        }
        [coder encodeBool:YES forKey:VibeRanKey(identifier)];
    }];
    // Every observer this process knows that the decode did not run is
    // marked, so a build that reads an absent mark as run still misses.
    for (NSString *identifier in AudioWaveformObserver.identifiers) {
        if (self.results[identifier] == nil) {
            [coder encodeBool:NO forKey:VibeRanKey(identifier)];
        }
    }
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
        // A result that will not read is kept as NaN rather than dropped: the
        // observer ran, so the entry still covers it, and a bad value is no
        // reason to throw away good waveform data. Its reader decides.
        NSMutableDictionary<NSString *, NSNumber *> *results = [NSMutableDictionary dictionary];
        for (NSString *identifier in AudioWaveformObserver.identifiers) {
            if (![coder decodeBoolForKey:VibeRanKey(identifier)]) {
                continue;
            }
            id object = [coder decodeObjectForKey:identifier];
            if ([object isKindOfClass:NSNumber.class]) {
                results[identifier] = object;
            }
            else {
                results[identifier] = @(!object && [coder containsValueForKey:identifier]
                                        ? [coder decodeDoubleForKey:identifier] : NAN);
            }
        }
        _results = [results copy];
    }
    return self;
}

@end
