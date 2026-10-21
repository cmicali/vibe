//
//  AudioWaveform.mm
//  Vibe
//

#import "AudioWaveform.h"

#include <vector>

// See the declaration in AudioWaveform.h.
const int kCodableAudioWaveformVersion = 7;

// What a result may be made of: the property-list classes, and no others.
static NSSet<Class> *VibeWaveformResultClasses(void) {
    static NSSet<Class> *classes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classes = [NSSet setWithObjects:NSDictionary.class, NSArray.class, NSString.class,
                   NSNumber.class, NSDate.class, NSData.class, nil];
    });
    return classes;
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
    // An archive of its own, with secure coding, so the read can hold it to
    // the allowed classes whatever the outer coder does. The entry lists its
    // own identifiers, so a reader needs no list of names.
    NSError *error = nil;
    NSData *results = [NSKeyedArchiver archivedDataWithRootObject:self.results requiringSecureCoding:YES error:&error];
    if (!results) {
        LogError(@"Waveform results would not archive: %@", error);
        results = [NSData data];
    }
    [coder encodeBytes:(const uint8_t *)results.bytes length:results.length forKey:@"results"];
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
        // Results that will not read reject the entry, as a bad summary
        // does. Its observers then run again on the next decode.
        bytes = [coder decodeBytesForKey:@"results" returnedLength:&length];
        NSData *data = bytes ? [NSData dataWithBytes:bytes length:length] : nil;
        id results = data ? [NSKeyedUnarchiver unarchivedObjectOfClasses:VibeWaveformResultClasses()
                                                                fromData:data error:NULL] : nil;
        if (![results isKindOfClass:NSDictionary.class]) {
            return nil;
        }
        for (id identifier in results) {
            if (![identifier isKindOfClass:NSString.class]) {
                return nil;
            }
        }
        _results = [results copy];
    }
    return self;
}

@end
