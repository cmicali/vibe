//
//  AudioPlayer+BitPerfect.m
//  Vibe
//

#import "AudioPlayer+BitPerfect.h"
#import "AudioPlayerInternal.h"
#import "AudioFX.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import "HelperMacros.h"
#import "VibeMacros.h"

// Format changes and restoration wait, with the output stopped, for the
// device to confirm the write before the graph follows its rate.
static const NSTimeInterval kFormatSwitchDeadlineSeconds = 1.5;
static const useconds_t kFormatSwitchPollMicroseconds = 5000;

#pragma mark - Bit-perfect output (queue-side mechanism)

@implementation AudioPlayer (BitPerfectInternal)

// The chosen device when it is one the mode may drive, else nil: the one
// eligibility fold, shared by the report and the mechanism. During a device
// switch it is the destination, which configureOutputDeviceOnQueue: prepares
// and hogs before setOutputDeviceOnQueue: commits the id (a failed switch
// must not); the unit's own device would name the one the switch is leaving.
- (nullable AudioDevice *)eligibleRequestedDeviceOnQueue {
    NSInteger requested = self.currentlyRequestedAudioDeviceId;
    if (_rebindDeviceID != kAudioObjectUnknown) {
        requested = (NSInteger)_rebindDeviceID;
    }
    if (requested < 0) {
        return nil;
    }
    AudioDevice *device = [[AudioDeviceManager sharedInstance] outputDeviceForId:requested];
    return (device && VibeBitPerfectDeviceEligible(device.transportType, _allowBitPerfectOnAnyDevice)) ? device : nil;
}

// The device the mode can apply to right now, else nil.
- (nullable AudioDevice *)bitPerfectDeviceOnQueue {
    if (!_bitPerfectWanted || !_outputUnit) {
        return nil; // off, or the debug pump, which has no device to prepare
    }
    return [self eligibleRequestedDeviceOnQueue];
}

// Reads the device and resolves the format the rules want for `file`: the
// stream, what it has now and what it should have. chosen == current when the
// device offers neither the file's rate nor a multiple, or nothing at the
// target rate.
- (BOOL)resolveOutputFormatOnQueueForFile:(AudioFileHandle *)file
                                   device:(AudioDevice *)device
                                   stream:(AudioStreamID *)stream
                                  current:(AudioStreamBasicDescription *)current
                                   chosen:(AudioStreamBasicDescription *)chosen {
    AudioStreamRangedDescription *formats = NULL;
    UInt32 count = 0;
    if (![CoreAudioUtil readOutputStream:stream physicalFormat:current
                        availableFormats:&formats count:&count
                             forDeviceID:(AudioDeviceID)device.deviceId]) {
        return NO;
    }
    AudioStreamBasicDescription source = *file.fileFormat.streamDescription;
    double targetRate = VibeBitPerfectTargetRate(source.mSampleRate, source.mChannelsPerFrame, formats, count);
    if (targetRate == 0 || !VibeBitPerfectChooseFormat(source, targetRate, formats, count, chosen)) {
        *chosen = *current;
    }
    free(formats);
    return YES;
}

- (BOOL)outputNeedsSwitchOnQueueForFile:(AudioFileHandle *)file {
    AudioDevice *device = [self bitPerfectDeviceOnQueue];
    if (!device) {
        return NO;
    }
    AudioStreamID stream = kAudioObjectUnknown;
    AudioStreamBasicDescription current = {0}, chosen = {0};
    if (![self resolveOutputFormatOnQueueForFile:file device:device stream:&stream
                                         current:&current chosen:&chosen]) {
        return YES; // unknown compatibility cannot splice
    }
    double mixerRate = [self masterBusFormatOnQueue].sampleRate;
    BOOL needsSwitch = VibeBitPerfectOutputNeedsSwitch(current, chosen, mixerRate);
#if VIBE_VERBOSE_LOGGING
    if (needsSwitch) {
        LogInfo(@"bit-perfect: %@ needs a switch: device %.0f Hz %u-bit flags 0x%x %u bytes/frame, chosen %.0f Hz %u-bit flags 0x%x %u bytes/frame, bus %.0f Hz",
                file.url.lastPathComponent, current.mSampleRate, (unsigned)current.mBitsPerChannel,
                (unsigned)current.mFormatFlags, (unsigned)current.mBytesPerFrame, chosen.mSampleRate,
                (unsigned)chosen.mBitsPerChannel, (unsigned)chosen.mFormatFlags, (unsigned)chosen.mBytesPerFrame, mixerRate);
    }
#endif
    return needsSwitch;
}

// The chosen device vanished: the mode cannot follow the fallback onto System
// Output. The off path verbatim — a confirmed removal retires any restore
// obligation. The shell persists System Output on the -1 announcement;
// the vanished device keeps its remembered modes.
- (void)abandonBitPerfectForVanishedDeviceOnQueue {
    if (!_bitPerfectWanted) {
        return;
    }
    LogInfo(@"bit-perfect: the chosen device vanished; turning the mode off");
    _bitPerfectWanted = NO;
    [self stopOutputOnQueue];
    [self leaveOutputDeviceOnQueue];
    // The source segment follows the mode at the next settlement or rebind.
    [self publishBitPerfectReportOnQueue];
}

- (BOOL)setOutputFormatOnQueue:(AudioStreamBasicDescription)format
                       stream:(AudioStreamID)stream device:(AudioDeviceID)deviceID {
    return [self performDiagnosticPhase:@"format write/confirmation" device:deviceID operation:^BOOL{
        return [self confirmOutputFormatOnQueue:format stream:stream device:deviceID];
    }];
}

- (BOOL)confirmOutputFormatOnQueue:(AudioStreamBasicDescription)format
                           stream:(AudioStreamID)stream device:(AudioDeviceID)deviceID {
    // TRAP: the stop this write follows is only queued on the unit; a hogged
    // device's format written under a running output strands its next start
    // with error 35. Wait for it.
    [_outputUnit waitUntilIdle];
    if (![CoreAudioUtil setPhysicalFormat:format forStream:stream]) {
        return NO;
    }
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + kFormatSwitchDeadlineSeconds;
    // TRAP: an accepted write precedes the nominal rate, so both are confirmed
    // before the graph follows the rate; a restoration must confirm the full
    // sample representation too, including packing.
    do {
        AudioStreamBasicDescription current = {0};
        Float64 rate = 0;
        if ([CoreAudioUtil readPhysicalFormat:&current forStream:stream]
                && VibePhysicalFormatsEquivalent(current, format)
                && [CoreAudioUtil readNominalSampleRate:&rate forDeviceID:deviceID]
                && rate == format.mSampleRate) {
            return YES;
        }
        usleep(kFormatSwitchPollMicroseconds);
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    LogWarn(@"bit-perfect: format confirmation deadline expired on device %u", deviceID);
    return NO;
}

- (void)prepareOutputOnQueueForFile:(AudioFileHandle *)file {
    [self performDiagnosticPhase:@"output preparation" device:self.currentlyRequestedAudioDeviceId operation:^BOOL{
        [self prepareOutputFormatOnQueueForFile:file];
        return YES; // confirmation failures are reported by the nested format phase
    }];
}

- (void)prepareOutputFormatOnQueueForFile:(AudioFileHandle *)file {
    AudioDevice *device = [self bitPerfectDeviceOnQueue];
    if (!device) {
        return; // the state publication that follows every caller publishes the report
    }
    AudioDeviceID deviceID = (AudioDeviceID)device.deviceId;
    if (![self setPreparedDeviceOnQueue:deviceID]) {
        return;
    }
    AudioStreamID stream = kAudioObjectUnknown;
    AudioStreamBasicDescription current = {0}, chosen = {0};
    if (![self resolveOutputFormatOnQueueForFile:file device:device stream:&stream
                                         current:&current chosen:&chosen]) {
        LogWarn(@"bit-perfect: could not read the output stream of %@", device.name);
        _preparedStreamID = kAudioObjectUnknown;
        memset(&_preparedFormat, 0, sizeof(_preparedFormat));
        return;
    }
    _preparedStreamID = stream;
    _preparedFormat = chosen;
    BOOL formatDiffers = !VibePhysicalFormatsEquivalent(chosen, current);
    if (VibeBitPerfectOutputNeedsSwitch(current, chosen, [self masterBusFormatOnQueue].sampleRate)) {
        // Bit-perfect edges are cuts or declicks, so a settlement mid-fade
        // loses at most a declick.
        [self stopOutputOnQueue];
    }
    if (formatDiffers) {
        // Restore is one slot: another device's outstanding restore is tried
        // first, and while it keeps failing this device keeps its format.
        BOOL owedElsewhere = _changedFormatDeviceID != kAudioObjectUnknown && _changedFormatDeviceID != deviceID;
        if (owedElsewhere) {
            [self restoreOutputFormatOnQueue]; // the output was stopped above
            owedElsewhere = _changedFormatDeviceID != kAudioObjectUnknown;
        }
        if (owedElsewhere) {
            LogWarn(@"bit-perfect: leaving device %u unchanged until device %u is restored",
                    deviceID, _changedFormatDeviceID);
        }
        else {
            // Remember what the device had before OUR first change. A slot already
            // naming this device keeps its older memory: the restore should land
            // on what the user had, not on the previous track's rate.
            if (_changedFormatDeviceID != deviceID) {
                _changedFormatDeviceID = deviceID;
                _changedFormatStreamID = stream;
                _formatBeforeChange = current;
            }
            NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
            BOOL confirmed = [self setOutputFormatOnQueue:chosen stream:stream device:deviceID];
            LogInfo(@"bit-perfect: %@ -> %.0f Hz %@%u in %.0f ms%@", device.name, chosen.mSampleRate,
                    VibePhysicalFormatIsFloat(chosen) ? @"f" : @"i", (unsigned)chosen.mBitsPerChannel,
                    (NSProcessInfo.processInfo.systemUptime - started) * 1000,
                    confirmed ? @"" : @" (not confirmed)");
            // What the device actually has now, not what was asked for.
            [CoreAudioUtil readPhysicalFormat:&current forStream:stream];
        }
    }
    // The pipeline follows the device: the bus, the FX segment and the unit
    // all run at its rate. Any file-rate conversion stays in the voice decoder.
    if (current.mSampleRate > 0 && current.mSampleRate != [self masterBusFormatOnQueue].sampleRate) {
        [self applyOutputRateOnQueue:current.mSampleRate];
    }
}

// The output is stopped at both ownership edges.
- (void)acquireExclusiveOutputOnQueue {
    AudioDevice *device = [self bitPerfectDeviceOnQueue];
    AudioDeviceID deviceID = device ? (AudioDeviceID)device.deviceId : kAudioObjectUnknown;
    if (!device || !_exclusiveOutputWanted
            || ![CoreAudioUtil supportsHogModeForDeviceID:deviceID]) {
        [self releaseExclusiveOutputOnQueue];
        return;
    }
    if (_hoggedDeviceID != deviceID) {
        [self releaseExclusiveOutputOnQueue];
        if (_hoggedDeviceID != kAudioObjectUnknown) {
            return; // never overwrite an outstanding release with a second device
        }
    }
    // Taking the system default moves the default elsewhere; the hosted unit
    // stays bound. A successful write followed by a failed read-back may still
    // own the device, so the obligation is recorded BEFORE the take.
    if (_hoggedDeviceID != deviceID) {
        [_outputUnit waitUntilIdle]; // an ownership edge: after the queued stop, as the format write
    }
    _hoggedDeviceID = deviceID;
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Phase: play %llu voice %llu exclusive context: requested %ld, bound %u",
            [self diagnosticPlayIdentifierOnQueue], _voice,
            (long)self.currentlyRequestedAudioDeviceId, [self activeOutputDeviceID]);
#endif
    if (![self performDiagnosticPhase:@"hog acquire" device:deviceID operation:^BOOL{
        return [CoreAudioUtil setHogOwnedByThisProcess:YES forDeviceID:deviceID];
    }]) {
        LogWarn(@"bit-perfect: could not confirm exclusive access to %@", device.name);
        [self releaseExclusiveOutputOnQueue]; // publishes
        return;
    }
    [self publishBitPerfectReportOnQueue];
}

- (void)releaseExclusiveOutputOnQueue {
    if (_hoggedDeviceID == kAudioObjectUnknown) {
        return;
    }
    [_outputUnit waitUntilIdle];
    // Retry once for a transient failure. The HAL helper reads before writing,
    // so a failed read-back after a successful release cannot toggle it back on.
    [CoreAudioUtil releaseDeviceObligation:&_hoggedDeviceID attempt:^BOOL{
        return [self performDiagnosticPhase:@"hog release" device:self->_hoggedDeviceID operation:^BOOL{
            return [CoreAudioUtil setHogOwnedByThisProcess:NO forDeviceID:self->_hoggedDeviceID];
        }];
    } isAbsent:^BOOL(AudioDeviceID deviceID) {
        return [[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:deviceID];
    }];
    if (_hoggedDeviceID != kAudioObjectUnknown) {
        LogWarn(@"bit-perfect: release still owed to device %u", _hoggedDeviceID);
    }
    [self publishBitPerfectReportOnQueue];
}


// Watch the prepared device's volume, balance, mute and nominal rate.
// kAudioObjectUnknown removes the listener. Copy the HAL block before adding
// it, because removal must receive the same block object.
- (BOOL)setPreparedDeviceOnQueue:(AudioDeviceID)deviceID {
    if (_preparedDeviceID == deviceID && (_outputLevelListener || deviceID == kAudioObjectUnknown)) {
        return YES;
    }
    // The third device obligation, retired like the other two: a vanished
    // device never accepts the removal, and a _preparedDeviceID left naming it
    // reads as "a device is prepared" to setOutputDeviceOnQueue:, so every
    // later bind would rebuild the graph.
    if (_outputLevelListener) {
        AudioObjectPropertyListenerBlock listener = _outputLevelListener;
        if ([CoreAudioUtil releaseDeviceObligation:&_preparedDeviceID attempt:^BOOL{
            return [CoreAudioUtil removeOutputLevelListener:listener queue:self->_queue
                                                forDeviceID:self->_preparedDeviceID];
        } isAbsent:^BOOL(AudioDeviceID absentID) {
            return [[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:absentID];
        }]) {
            _outputLevelListener = nil;
            _preparedStreamID = kAudioObjectUnknown;
            memset(&_preparedFormat, 0, sizeof(_preparedFormat));
        }
        else {
            LogWarn(@"bit-perfect: output listener removal still owed to device %u", _preparedDeviceID);
            return NO; // retain the HAL's removal handle; never accumulate orphaned listeners
        }
    }
    if (_preparedDeviceID != deviceID) {
        _preparedDeviceID = deviceID;
        _preparedStreamID = kAudioObjectUnknown;
        memset(&_preparedFormat, 0, sizeof(_preparedFormat));
    }
    if (deviceID == kAudioObjectUnknown) {
        return YES;
    }
    __weak AudioPlayer *weakSelf = self;
    AudioObjectPropertyListenerBlock listener = [^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf && strongSelf->_bitPerfectWanted && strongSelf->_preparedDeviceID == deviceID) {
            for (UInt32 i = 0; i < count; i++) {
                AudioObjectPropertySelector selector = addresses[i].mSelector;
#if VIBE_VERBOSE_LOGGING
                LogInfo(@"Callback: bit-perfect device listener, '%c%c%c%c' changed on device %u", (char)(selector >> 24),
                        (char)(selector >> 16), (char)(selector >> 8), (char)selector, deviceID);
#endif
                if (selector == kAudioDevicePropertyNominalSampleRate) {
                    // Another process moved the prepared device's rate: the
                    // rebind's prepare sets the mode's format back. Vibe's own
                    // writes arrive with the graph already at the rate, a
                    // no-op; a vanished device is the device-list observer's.
                    Float64 rate = 0;
                    if ([CoreAudioUtil readNominalSampleRate:&rate forDeviceID:deviceID]
                            && rate != [strongSelf masterBusFormatOnQueue].sampleRate
                            && ![CoreAudioUtil deviceIsConfirmedDead:deviceID]) {
                        LogInfo(@"bit-perfect: device %u moved to %.0f Hz under the graph; rebinding", deviceID, rate);
                        [strongSelf configureOutputDeviceOnQueue:deviceID];
                        [strongSelf publishBitPerfectReportOnQueue];
                    }
                    break;
                }
                if (selector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume
                        || selector == kAudioHardwareServiceDeviceProperty_VirtualMainBalance
                        || selector == kAudioDevicePropertyVolumeScalar
                        || selector == kAudioDevicePropertyVolumeDecibels
                        || selector == kAudioDevicePropertyStereoPan
                        || selector == kAudioDevicePropertyMute
                        || selector == kAudioObjectPropertySelectorWildcard) {
                    strongSelf->_outputControlsDeviceID = kAudioObjectUnknown;
                    [strongSelf publishBitPerfectReportOnQueue];
                    break;
                }
            }
        }
    } copy];
    // Retry a transient registration failure once, and again at the next
    // prepare if both attempts fail. Keep the prepared format on that retry.
    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        if ([CoreAudioUtil addOutputLevelListener:listener queue:_queue forDeviceID:deviceID]) {
            _outputLevelListener = listener;
            _outputControlsDeviceID = kAudioObjectUnknown; // changes while unwatched were missed
            break;
        }
    }
    return YES; // a registration failure is reported as unconfirmed, and retried at the next prepare
}

// The output must be stopped. Retry once, then keep the obligation for the
// next leave or prepare (including quit). A second device cannot replace it.
- (void)restoreOutputFormatOnQueue {
    if (_changedFormatDeviceID == kAudioObjectUnknown) {
        return;
    }
    BOOL cleared = [CoreAudioUtil releaseDeviceObligation:&_changedFormatDeviceID attempt:^BOOL{
        BOOL restored = [self setOutputFormatOnQueue:self->_formatBeforeChange
                                             stream:self->_changedFormatStreamID device:self->_changedFormatDeviceID];
        if (restored) {
            LogInfo(@"bit-perfect: device %u restored to %.0f Hz %@%u", self->_changedFormatDeviceID,
                    self->_formatBeforeChange.mSampleRate, VibePhysicalFormatIsFloat(self->_formatBeforeChange) ? @"f" : @"i",
                    (unsigned)self->_formatBeforeChange.mBitsPerChannel);
        }
        return restored;
    } isAbsent:^BOOL(AudioDeviceID deviceID) {
        return [[AudioDeviceManager sharedInstance] knowsOutputDeviceIsAbsent:deviceID];
    }];
    if (cleared) {
        _changedFormatStreamID = kAudioObjectUnknown;
        memset(&_formatBeforeChange, 0, sizeof(_formatBeforeChange));
    }
    else {
        LogWarn(@"bit-perfect: format restore still owed to device %u", _changedFormatDeviceID);
    }
}

// Restore the original format, forget the prepared device and release it.
// Every step is idempotent, so this is free to call with nothing owed.
- (void)leaveOutputDeviceOnQueue {
    [self reconcileFXOnQueue];
    [self restoreOutputFormatOnQueue];
    [self setPreparedDeviceOnQueue:kAudioObjectUnknown];
    [self releaseExclusiveOutputOnQueue];
}

// Computes the report from its owners — the mode, the graph, the chosen
// device, the hog, the current file, the prepared device's physical format
// read live and its volume, balance and mute (cached while its listener
// stands), the device's reads bounded — and publishes the copy the shell reads, announcing it when it
// differs. Held while a device switch is rebuilding. It gates itself: off,
// once the zeroed Off report is out, a call is two ivar reads.
- (void)publishBitPerfectReportOnQueue {
    if (_rebindDeviceID != kAudioObjectUnknown || (!_bitPerfectWanted && !_bitPerfectReport.enabled)) {
        return;
    }
    VibeBitPerfectReport report = {0};
    NSString *unconfirmed = nil;
    BOOL controlsCached = NO;
#if VIBE_VERBOSE_LOGGING
    BOOL readDevice = NO;
    uint64_t readStarted = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif
    report.enabled = _bitPerfectWanted;
    report.playerVolume = self.volume;
    AudioDevice *device = _bitPerfectWanted ? [self eligibleRequestedDeviceOnQueue] : nil;
    report.eligibleDevice = (device != nil);
    if (device && (AudioDeviceID)device.deviceId == _preparedDeviceID) {
#if VIBE_VERBOSE_LOGGING
        readDevice = YES;
#endif
        AudioFileHandle *file = _file; // queue-confined writer; the promoted splice file included
        UInt32 channels = file.fileFormat.channelCount;
        // No file (Loading) asks for no channels; the last track's reading covers it.
        controlsCached = _outputLevelListener && _outputControlsDeviceID == _preparedDeviceID
                && _outputControlsStreamID == _preparedStreamID
                && (_outputControlsChannels == channels || channels == 0);
        // Every device read in one bounded read: this rides every state
        // publication, and a hung device must not hold the queue for each.
        AudioDeviceID prepared = _preparedDeviceID;
        AudioStreamID stream = _preparedStreamID;
        NSArray<NSNumber *> *channelMap = _outputUnit.channelMap;
        BOOL readControls = !controlsCached;
        BOOL readOwner = NO;
        readOwner = _hoggedDeviceID == prepared;
        __block AudioStreamBasicDescription devicePhysical = {0};
        __block BOOL formatRead = NO, controlsRead = NO, ownerRead = NO, mapPreserves = NO, deviceMuted = NO;
        __block Float32 deviceVolume = 1, deviceBalance = 0.5f;
        __block pid_t owner = -1;
        BOOL answered = [CoreAudioUtil performBoundedRead:^{
            formatRead = [CoreAudioUtil readPhysicalFormat:&devicePhysical forStream:stream];
            if (readOwner) ownerRead = [CoreAudioUtil readHogOwner:&owner forDeviceID:prepared];
            if (readControls) {
                controlsRead = [CoreAudioUtil readOutputVolume:&deviceVolume balance:&deviceBalance mute:&deviceMuted
                                                      channels:channels inStream:stream forDeviceID:prepared];
            }
            mapPreserves = channels > 0 && [CoreAudioUtil channelMap:channelMap preservesChannels:channels inStream:stream
                                                physicalChannelCount:devicePhysical.mChannelsPerFrame];
        } within:kDeviceReadWaitSeconds late:nil];
        // A read that timed out is still writing its results: none is looked at.
        BOOL readFormat = answered && formatRead;
        AudioStreamBasicDescription physical = readFormat ? devicePhysical : (AudioStreamBasicDescription){0};
        AVAudioFormat *mixerFormat = [self masterBusFormatOnQueue];
        AVAudioFormat *unitFormat = _outputUnit.format;
        report.sampleRate = physical.mSampleRate;
        report.bitsPerChannel = physical.mBitsPerChannel;
        report.isFloat = VibePhysicalFormatIsFloat(physical);
        // Named rather than folded into one flag: "switch failed" alone does
        // not say which condition failed, and the debug info log is read for it.
        AudioDeviceID bound = [self activeOutputDeviceID];
        unconfirmed = !answered ? @"the device did not answer in time"
                : !readFormat ? @"the device's format could not be read"
                : [self varispeedPresentOnQueue] ? @"a varispeed is in the chain"
                : self.fx.connected ? @"the FX bus is in the chain"
                : !_outputLevelListener ? @"the device listener is missing"
                : bound != _preparedDeviceID
                        ? [NSString stringWithFormat:@"the output unit is bound to device %u", bound]
                : !VibePhysicalFormatsEquivalent(physical, _preparedFormat) ? @"the device left the format set on it"
                : mixerFormat.sampleRate != physical.mSampleRate
                        ? [NSString stringWithFormat:@"the bus runs at %.0f Hz", mixerFormat.sampleRate]
                : unitFormat.sampleRate != physical.mSampleRate
                        ? [NSString stringWithFormat:@"the output unit pulls at %.0f Hz", unitFormat.sampleRate]
                : nil;
        report.formatConfirmed = (unconfirmed == nil);
        report.hogWanted = _exclusiveOutputWanted; // the device is eligible and prepared by here
        report.exclusive = readOwner && answered && ownerRead && owner == getpid();
        if (readControls) {
            BOOL read = answered && controlsRead;
            _outputControlsVolume = read ? deviceVolume : 1;
            _outputControlsBalance = read ? deviceBalance : 0.5f;
            _outputControlsMuted = read && deviceMuted;
            // A failed read is never kept, so the next publication tries again.
            _outputControlsDeviceID = read ? _preparedDeviceID : kAudioObjectUnknown;
            _outputControlsStreamID = _preparedStreamID;
            _outputControlsChannels = channels;
        }
        report.softwareVolume = _outputControlsVolume;
        report.balance = _outputControlsBalance;
        report.muted = _outputControlsMuted;
        if (_outputControlsDeviceID != _preparedDeviceID) {
            unconfirmed = unconfirmed ?: @"the device's volume could not be read";
            report.formatConfirmed = NO;
        }
        if (file) {
            AudioStreamBasicDescription source = *file.fileFormat.streamDescription;
            // Keep the bus one-to-one; wider hardware is transparent only
            // when the AU's actual map preserves the prepared stream's pair.
            report.channelsMatch = channels > 0
                    && file.processingFormat.channelCount == channels
                    && mixerFormat.channelCount == channels
                    && unitFormat.channelCount == channels
                    && answered && mapPreserves;
            report.rateExact = (physical.mSampleRate == source.mSampleRate);
            report.depthOK = VibePhysicalFormatSatisfies(physical, source,
                                                         *file.processingFormat.streamDescription);
            report.sourceBits = VibeSourceBitDepth(source);
        }
    }
#if VIBE_VERBOSE_LOGGING
    // Every state publication and fade completion lands here, on the player
    // queue, so a slow device read delays the next transport action by as much.
    double readMilliseconds = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - readStarted) / 1e6;
    if (readDevice && (readMilliseconds >= 2 || !controlsCached)) {
        LogInfo(@"bit-perfect: report read device %u for %.1f ms (volume/balance/mute %@)",
                _preparedDeviceID, readMilliseconds, controlsCached ? @"cached" : @"read from the device");
    }
#endif
    os_unfair_lock_lock(&_stateLock);
    report.hasTrack = _bitPerfectWanted && _state == VibePlayerStatePlaying;
    report.status = VibeBitPerfectFold(report);
    BOOL changed = !VibeBitPerfectReportsEqual(_bitPerfectReport, report);
    _bitPerfectReport = report;
    os_unfair_lock_unlock(&_stateLock);
    if (!changed) {
        return;
    }
    if (unconfirmed) {
        LogWarn(@"bit-perfect: format not confirmed, because %@", unconfirmed);
    }
    [self announceBitPerfectReportChange];
}

- (void)refoldBitPerfectReportForPlayerVolumeOnQueue:(float)volume {
    os_unfair_lock_lock(&_stateLock);
    VibeBitPerfectReport report = _bitPerfectReport;
    report.playerVolume = volume;
    report.status = VibeBitPerfectFold(report);
    BOOL changed = report.enabled && !VibeBitPerfectReportsEqual(_bitPerfectReport, report);
    if (changed) {
        _bitPerfectReport = report;
    }
    os_unfair_lock_unlock(&_stateLock);
    if (changed) {
        [self announceBitPerfectReportChange];
    }
}

- (void)announceBitPerfectReportChange {
    run_on_main_thread({
        id<AudioPlayerDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(audioPlayerDidChangeBitPerfectReport:)]) {
            [delegate audioPlayerDidChangeBitPerfectReport:self];
        }
    });
}

@end

#pragma mark - Bit-perfect output (public API, declared in AudioPlayer+BitPerfect.h)

@implementation AudioPlayer (BitPerfect)

- (VibeBitPerfectReport)bitPerfectReport {
    os_unfair_lock_lock(&_stateLock);
    VibeBitPerfectReport report = _bitPerfectReport;
    os_unfair_lock_unlock(&_stateLock);
    return report;
}

- (void)setBitPerfectOutput:(BOOL)bitPerfectOutput exclusiveOutput:(BOOL)exclusiveOutput enableFX:(BOOL)enableFX allowAnyDevice:(BOOL)allowAnyDevice {
    if (bitPerfectOutput || !enableFX) {
        [self clearFXIntent];
    }
    dispatch_async(_queue, ^{
        if (self->_terminating) return;
        BOOL desiredBitPerfect = bitPerfectOutput, desiredExclusive = exclusiveOutput;
        NSInteger requested = self.currentlyRequestedAudioDeviceId;
        NSString *uid = requested >= 0
                ? [AudioDeviceManager.sharedInstance outputDeviceForId:requested].uid
                : self->_pendingSavedDeviceUID;
        // A global FX edit can queue behind a device switch. Its captured
        // modes belong to the old device, so resolve the queue's current UID.
        [self readOutputModesForDeviceUID:uid bitPerfectOutput:&desiredBitPerfect exclusiveOutput:&desiredExclusive];
        BOOL changed = self->_bitPerfectWanted != desiredBitPerfect
                || (self->_fxEnabled && !self->_bitPerfectWanted) != (enableFX && !desiredBitPerfect);
        changed |= desiredBitPerfect && self->_allowBitPerfectOnAnyDevice != allowAnyDevice;
        self->_allowBitPerfectOnAnyDevice = allowAnyDevice;
        self->_fxEnabled = enableFX;
        self->_bitPerfectWanted = desiredBitPerfect;
        changed |= desiredBitPerfect && self->_exclusiveOutputWanted != desiredExclusive;
        self->_exclusiveOutputWanted = desiredExclusive;
        // Reapplying settings must not interrupt playback. An exclusive
        // preference saved while bit-perfect is off cannot affect the graph.
        if (!changed) {
            return;
        }
        if (desiredBitPerfect) {
            [self resolvePendingSavedOutputDeviceOnQueue];
        }
        // A saved device can be absent at launch. Turning the mode off on
        // System Output must restore varispeed on the current track too.
        AudioDeviceID deviceID = requested >= 0 ? (AudioDeviceID)requested : kAudioObjectUnknown;
        // Rebuild the route even without a resolved device or during an open.
        // A loaded track resumes in place; an open keeps its pending intent.
        [self configureOutputDeviceOnQueue:deviceID];
        [self publishBitPerfectReportOnQueue];
    });
}

#pragma mark - Diagnostics

static NSString *VibeBitPerfectStatusName(VibeBitPerfectStatus status) {
    switch (status) {
        case VibeBitPerfectStatusOff:               return @"off";
        case VibeBitPerfectStatusIdle:              return @"idle";
        case VibeBitPerfectStatusActive:            return @"active";
        case VibeBitPerfectStatusRateUnsupported:   return @"rateUnsupported";
        case VibeBitPerfectStatusSwitchFailed:      return @"switchFailed";
        case VibeBitPerfectStatusChannelConversion: return @"channelConversion";
        case VibeBitPerfectStatusDepthInsufficient: return @"depthInsufficient";
        case VibeBitPerfectStatusMuted:             return @"muted";
        case VibeBitPerfectStatusVolumeScaled:      return @"volumeScaled";
        case VibeBitPerfectStatusExclusiveRefused:  return @"exclusiveRefused";
        case VibeBitPerfectStatusSourceLossy:       return @"sourceLossy";
    }
    return @"unknown";
}

- (NSDictionary<NSString *, id> *)bitPerfectReportDictionary {
    VibeBitPerfectReport r = self.bitPerfectReport;
    return @{
        @"enabled": @(r.enabled),
        @"status": VibeBitPerfectStatusName(r.status),
        @"sampleRate": @(r.sampleRate),
        @"bitsPerChannel": @(r.bitsPerChannel),
        @"sourceBits": @(r.sourceBits),
        @"isFloat": @(r.isFloat),
        @"softwareVolume": @(r.softwareVolume),
        @"balance": @(r.balance),
        @"playerVolume": @(r.playerVolume),
        @"muted": @(r.muted),
        @"eligibleDevice": @(r.eligibleDevice),
        @"hasTrack": @(r.hasTrack),
        @"rateExact": @(r.rateExact),
        @"formatConfirmed": @(r.formatConfirmed),
        @"depthOK": @(r.depthOK),
        @"channelsMatch": @(r.channelsMatch),
        @"hogWanted": @(r.hogWanted),
        @"exclusive": @(r.exclusive),
    };
}

@end
