//
//  AudioLevelTap.m
//  Vibe
//

#import "AudioLevelTap.h"

#import "AudioLevelAnalyzer.h"
#import "AudioLevelPublisherInternal.h"

// The installed block owns this object, and the object owns every raw pointer
// it uses. That ownership is the reset guarantee: abandon may drop AudioPlayer's
// reference without freeing state underneath a late defunct-engine callback.
@interface AudioLevelTapSession : NSObject {
@public
    VibeAudioLevelAnalyzer *_analyzer;
    AudioLevelPublisher *_publisher;
    VibeLevelPublisherState *_publisherState;
    uint64_t _session;
}
@end

@implementation AudioLevelTapSession
- (void)dealloc {
    VibeAudioLevelAnalyzerDestroy(_analyzer);
}
@end

@implementation AudioLevelTap {
    AudioLevelTapSession *_tapSession;
    AVAudioNode *_node;
    BOOL _installed;
}

- (instancetype)initWithNode:(AVAudioNode *)node
                     publisher:(AudioLevelPublisher *)publisher
             normalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode {
    self = [super init];
    if (!self) {
        return nil;
    }
    AVAudioFormat *format = [node outputFormatForBus:0];
    if (!publisher || format.sampleRate <= 0 || format.channelCount == 0) {
        LogWarn(@"AudioLevelTap: bus 0 has no usable format, no levels");
        return nil;
    }

    AudioLevelTapSession *tapSession = [[AudioLevelTapSession alloc] init];
    if (!tapSession) {
        LogError(@"AudioLevelTap: session allocation failed, no levels");
        return nil;
    }
    tapSession->_analyzer = VibeAudioLevelAnalyzerCreate(format.sampleRate,
                                                         normalizationMode);
    if (!tapSession->_analyzer) {
        LogError(@"AudioLevelTap: analyzer allocation failed, no levels");
        return nil;
    }
    tapSession->_publisher = publisher;
    tapSession->_publisherState = [publisher publisherState];
    tapSession->_session = [publisher beginSession];

    @try {
        [node installTapOnBus:0
                   bufferSize:(AVAudioFrameCount)VibeLevelTapBufferFrameCount(format.sampleRate)
                       format:nil
                        block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
#if DEBUG
            VibeLevelPublisherRecordCallback(tapSession->_publisherState,
                                              buffer.frameLength,
                                              buffer.format.sampleRate);
#endif
            // Mixer/output taps normally deliver non-interleaved float32. Fail
            // closed if a graph ever violates that shape, and rebind the pure
            // analyzer from the format actually delivered rather than the
            // pre-install query used for its initial configuration and the
            // requested callback size.
            if (buffer.format.interleaved || !buffer.floatChannelData
                    || !VibeAudioLevelAnalyzerSetSampleRate(
                            tapSession->_analyzer, buffer.format.sampleRate)) {
                return;
            }
            float callbackLevels[kLevelBandCount];
            NSUInteger windows = VibeAudioLevelAnalyzerConsume(
                    tapSession->_analyzer,
                    buffer.floatChannelData,
                    buffer.format.channelCount,
                    buffer.frameLength,
                    callbackLevels);
#if DEBUG
            VibeLevelPublisherRecordAnalyzedWindows(tapSession->_publisherState,
                                                     windows);
#endif
            if (windows > 0) {
                VibeLevelPublisherPublish(tapSession->_publisherState,
                                          tapSession->_session,
                                          callbackLevels);
            }
        }];
    }
    @catch (NSException *exception) {
        [publisher endSession:tapSession->_session];
        LogWarn(@"AudioLevelTap: install failed (%@)", exception.reason);
        return nil;
    }

    _tapSession = tapSession;
    _node = node;
    _installed = YES;
    LogDebug(@"AudioLevelTap: installed at %.0f Hz, %lu-frame FFT, %u-frame request",
             format.sampleRate,
             (unsigned long)VibeAudioLevelAnalyzerFFTSize(tapSession->_analyzer),
             VibeLevelTapBufferFrameCount(format.sampleRate));
    return self;
}

- (void)remove {
    if (!_installed) {
        return;
    }
    [_tapSession->_publisher endSession:_tapSession->_session];
    [_node removeTapOnBus:0];
    _installed = NO;
    _node = nil;
    _tapSession = nil;
}

- (void)abandon {
    if (_installed) {
        [_tapSession->_publisher endSession:_tapSession->_session];
    }
    _installed = NO;
    _node = nil;
    _tapSession = nil;
}

- (void)dealloc {
    [self remove];
}

@end
