//
//  VibeBenchComponentsPitch.mm
//  VibeBenchComponents
//
//  The pitch fader's stage, AudioVarispeed, and beside it Apple's Varispeed
//  unit, which it replaced, hosted as the render hosted it: so the two
//  compare in one harness. Earlier versions have the Apple variants only.
//
//  Both convert 30 s of stereo noise out at 48 kHz, in the 512-frame slices
//  of a typical output cycle, at the fader's −8%, +4% and +16%. Both copy
//  their input from the noise, as the render served it from the bus. Vibe's
//  stage builds its kernel inside the measurement, about 1.5 ms the first
//  time and 0.1 ms after.
//

#import "VibeBenchComponents.h"
#import <AudioToolbox/AudioToolbox.h>
#include <memory>

static const double kPitchSeconds = 30, kPitchRate = 48000;
static const uint32_t kPitchSlice = 512;
// The noise both read: enough frames for the widest ratio's 30 s.
static const uint32_t kPitchNoiseFrames = 1u << 21;

static std::shared_ptr<std::vector<float>> VibeBenchComponentsPitchNoise(void) {
    static std::shared_ptr<std::vector<float>> noise;
    if (!noise) {
        noise = std::make_shared<std::vector<float>>((size_t)kPitchNoiseFrames * 2);
        VibeBenchComponentsNoise(noise->data(), noise->size(), 33333);
    }
    return noise;
}

static std::string VibeBenchComponentsPitchName(const char *prefix, int percent) {
    return std::string(prefix) + (percent > 0 ? "+" : "") + std::to_string(percent);
}

#pragma mark - Apple's Varispeed

// Both converters' input, served from the noise from a cursor, a copy as the
// render's bus served it.
struct VibeBenchComponentsVarispeedSource {
    const float *channels[2];
    uint32_t cursor;
};

static void VibeBenchComponentsVarispeedServe(VibeBenchComponentsVarispeedSource *source, UInt32 frames,
                                              AudioBufferList *data) CA_REALTIME_API {
    for (UInt32 c = 0; c < 2 && c < data->mNumberBuffers; c++) {
        memcpy(data->mBuffers[c].mData, source->channels[c] + source->cursor, frames * sizeof(float));
    }
    source->cursor += frames;
}

static OSStatus VibeBenchComponentsVarispeedInput(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *stamp,
                                                  UInt32 bus, UInt32 frames, AudioBufferList *data) {
    VibeBenchComponentsVarispeedServe((VibeBenchComponentsVarispeedSource *)refCon, frames, data);
    return noErr;
}

// As the render hosted it: stereo float32 at the bus rate, 4096 frames per
// slice at most, the highest render quality. NULL when it cannot be hosted.
static AudioUnit VibeBenchComponentsHostVarispeed(VibeBenchComponentsVarispeedSource *source) {
    AudioComponentDescription description = {kAudioUnitType_FormatConverter, kAudioUnitSubType_Varispeed,
                                             kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    AudioUnit unit = NULL;
    if (!component || AudioComponentInstanceNew(component, &unit) != noErr) {
        return NULL;
    }
    AudioStreamBasicDescription format = {
        .mSampleRate = kPitchRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 2, .mBitsPerChannel = 32,
    };
    UInt32 maxFrames = 4096, quality = kRenderQuality_Max;
    AURenderCallbackStruct input = {VibeBenchComponentsVarispeedInput, source};
    OSStatus status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
    status |= AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof(format));
    status |= AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames,
                                   sizeof(maxFrames));
    status |= AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &input, sizeof(input));
    status |= AudioUnitSetProperty(unit, kAudioUnitProperty_RenderQuality, kAudioUnitScope_Global, 0, &quality, sizeof(quality));
    if (status != noErr || AudioUnitInitialize(unit) != noErr) {
        AudioComponentInstanceDispose(unit);
        return NULL;
    }
    return unit;
}

static void VibeBenchComponentsRegisterAppleVarispeed(void) {
    for (int percent : {-8, 4, 16}) {
        auto source = std::make_shared<VibeBenchComponentsVarispeedSource>();
        auto unit = std::make_shared<AudioUnit>((AudioUnit)NULL);
        VibeBenchComponentsAdd("pitch", VibeBenchComponentsPitchName("apple", percent), "audio s", [source, unit]() -> double {
            auto noise = VibeBenchComponentsPitchNoise();
            source->channels[0] = noise->data();
            source->channels[1] = noise->data() + kPitchNoiseFrames;
            if (!*unit) {
                *unit = VibeBenchComponentsHostVarispeed(source.get());
            }
            return *unit ? kPitchSeconds : -1;
        }, [source, unit, percent]() {
            AudioUnitReset(*unit, kAudioUnitScope_Global, 0);
            AudioUnitSetParameter(*unit, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, 1.0f + percent / 100.0f, 0);
            source->cursor = 0;
            std::vector<float> left(kPitchSlice), right(kPitchSlice);
            struct {
                UInt32 count;
                AudioBuffer buffers[2];
            } list;
            AudioTimeStamp stamp = {};
            stamp.mFlags = kAudioTimeStampSampleTimeValid;
            for (uint32_t done = 0; done < (uint32_t)(kPitchSeconds * kPitchRate); done += kPitchSlice) {
                list.count = 2;
                list.buffers[0] = (AudioBuffer){1, kPitchSlice * 4, left.data()};
                list.buffers[1] = (AudioBuffer){1, kPitchSlice * 4, right.data()};
                AudioUnitRenderActionFlags flags = 0;
                AudioUnitRender(*unit, &flags, &stamp, 0, kPitchSlice, (AudioBufferList *)&list);
                stamp.mSampleTime += kPitchSlice;
            }
        });
    }
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterAppleVarispeed)

#pragma mark - Vibe's stage

#if __has_include("AudioVarispeed.h")
#import "AudioVarispeed.h"

// The stage's source, served from the noise as the Apple unit's is.
static OSStatus VibeBenchComponentsStageInput(void *context, const AudioTimeStamp *stamp, UInt32 frames,
                                              AudioBufferList *into) CA_REALTIME_API {
    VibeBenchComponentsVarispeedServe((VibeBenchComponentsVarispeedSource *)context, frames, into);
    return noErr;
}

// The whole stage, as the render runs it: its first slice plays the source
// directly while the converter's past is recorded, and the rest convert.
static void VibeBenchComponentsRegisterPitch(void) {
    for (int percent : {-8, 4, 16}) {
        auto source = std::make_shared<VibeBenchComponentsVarispeedSource>();
        VibeBenchComponentsAdd("pitch", VibeBenchComponentsPitchName("", percent), "audio s", [source]() -> double {
            auto noise = VibeBenchComponentsPitchNoise();
            source->channels[0] = noise->data();
            source->channels[1] = noise->data() + kPitchNoiseFrames;
            return kPitchSeconds;
        }, [source, percent]() {
            VibeVarispeed *stage = VibeVarispeedCreate(2, kPitchSlice);
            VibeVarispeedTable *replaced = NULL;
            VibeVarispeedSetPitch(stage, percent, &replaced);
            source->cursor = 0;
            std::vector<float> left(kPitchSlice), right(kPitchSlice);
            VibeStereoBufferList out = { 2, {{ 1, kPitchSlice * 4, left.data() }, { 1, kPitchSlice * 4, right.data() }} };
            AudioTimeStamp stamp = {};
            for (uint32_t done = 0; done < (uint32_t)(kPitchSeconds * kPitchRate); done += kPitchSlice) {
                VibeVarispeedRender(stage, VibeBenchComponentsStageInput, source.get(), &stamp, kPitchSlice, (AudioBufferList *)&out);
            }
            VibeVarispeedFree(stage);
        });
    }
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterPitch)
#endif
