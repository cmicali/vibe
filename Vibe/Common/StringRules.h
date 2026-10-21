//
//  StringRules.h
//  Vibe
//
//  The one place a library's code or identifier becomes a STR_* string: the
//  play failure's status line, the link failure's message, and the waveform
//  styles' names. The engine, the link store and the renderers hand out
//  codes and identifiers and read no strings.
//

#import <Foundation/Foundation.h>
#import "AppSettings.h"
#import "AudioError.h"
#import "LinkStore.h"
#import "VibeStrings.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Playback

// Short: the title line names the track, and the log has the full text.
// VibeAudioErrorNotPlaying is filtered out before this as benign
// (AudioErrorRules.h). No default, so a new code is a compile warning, not
// the generic line. An underlying error of ours is the more specific cause:
// a refused start arrives wrapped in the caller's "could not resume".
static inline NSString *VibeStatusForPlayError(NSError *error) {
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying.domain isEqualToString:kVibeAudioErrorDomain]) {
        return VibeStatusForPlayError(underlying);
    }
    if ([error.domain isEqualToString:kVibeAudioErrorDomain]) {
        switch ((VibeAudioErrorCode)error.code) {
            case VibeAudioErrorFileOpenTimedOut:   return STR_ERROR_LOAD_TIMEOUT;
            case VibeAudioErrorFileOpenFailed:     return STR_ERROR_OPEN_FAILED;
            case VibeAudioErrorEngineStartFailed:  return STR_ERROR_ENGINE_START_FAILED;
            case VibeAudioErrorDeviceUnavailable:  return STR_ERROR_DEVICE_UNAVAILABLE;
            case VibeAudioErrorDeviceInUse:        return STR_ERROR_DEVICE_IN_USE;
            case VibeAudioErrorConnectionLost:     return STR_ERROR_CONNECTION_LOST;
            case VibeAudioErrorNotPlaying:         break;
        }
    }
    return STR_ERROR_PLAYBACK_GENERIC;
}

#pragma mark - Links

// What the shell shows for a failed open: the error's link.error string, or
// its short link.status string when brief. A Server error names its status.
// Any error outside the link domain reads as unreachable. A disk failure is
// one. Nil for a cancel, which shows nothing.
static inline NSString *_Nullable VibeLinkMessageForError(NSError *_Nullable error, BOOL brief) {
    if (![error.domain isEqualToString:VibeLinkErrorDomain]) {
        return brief ? STR_LINK_STATUS_UNREACHABLE : STR_LINK_ERROR_UNREACHABLE;
    }
    switch ((VibeLinkError)error.code) {
        case VibeLinkErrorInvalid:      return brief ? STR_LINK_STATUS_INVALID : STR_LINK_ERROR_INVALID;
        case VibeLinkErrorInsecure:     return brief ? STR_LINK_STATUS_INSECURE : STR_LINK_ERROR_INSECURE;
        case VibeLinkErrorLocalNetwork: return brief ? STR_LINK_STATUS_LOCAL_NETWORK : STR_LINK_ERROR_LOCAL_NETWORK;
        case VibeLinkErrorNotFound:     return brief ? STR_LINK_STATUS_NOT_FOUND : STR_LINK_ERROR_NOT_FOUND;
        case VibeLinkErrorDenied:       return brief ? STR_LINK_STATUS_DENIED : STR_LINK_ERROR_DENIED;
        case VibeLinkErrorNotAudio:     return brief ? STR_LINK_STATUS_NOT_AUDIO : STR_LINK_ERROR_NOT_AUDIO;
        case VibeLinkErrorNoSize:       return brief ? STR_LINK_STATUS_NO_SIZE : STR_LINK_ERROR_NO_SIZE;
        case VibeLinkErrorLiveStream:   return brief ? STR_LINK_STATUS_LIVE_STREAM : STR_LINK_ERROR_LIVE_STREAM;
        case VibeLinkErrorServer:
            return [NSString stringWithFormat:brief ? STR_LINK_STATUS_SERVER : STR_LINK_ERROR_SERVER,
                                              (long)[error.userInfo[VibeHTTPErrorStatusCodeKey] integerValue]];
        case VibeLinkErrorICloudPrivate:
            return brief ? STR_LINK_STATUS_ICLOUD_PRIVATE : STR_LINK_ERROR_ICLOUD_PRIVATE;
        case VibeLinkErrorICloudFolder: return brief ? STR_LINK_STATUS_ICLOUD_FOLDER : STR_LINK_ERROR_ICLOUD_FOLDER;
        case VibeLinkErrorICloudUnreadable:
            return brief ? STR_LINK_STATUS_ICLOUD_UNREADABLE : STR_LINK_ERROR_ICLOUD_UNREADABLE;
        case VibeLinkErrorCancelled:    return nil;
        case VibeLinkErrorNone:
        case VibeLinkErrorUnreachable:
            break;
    }
    return brief ? STR_LINK_STATUS_UNREACHABLE : STR_LINK_ERROR_UNREACHABLE;
}

#pragma mark - Waveform styles

// Every registered style's name, keyed by its WaveformRendererRegistry
// identifier. An unregistered identifier reads as itself. Detailed's four
// types share its name. StringRulesTests holds the table to the registry.
static inline NSString *VibeWaveformStyleDisplayName(NSString *identifier) {
    NSDictionary<NSString *, NSString *> *names = @{
        @"basic": STR_WAVEFORM_STYLE_BASIC,
        @"cupertino": STR_WAVEFORM_STYLE_CUPERTINO,
        @"cupertino_basic": STR_WAVEFORM_STYLE_CUPERTINO_BASIC,
        @"sonic_cirrus": STR_WAVEFORM_STYLE_SONIC_CIRRUS,
        @"detailed": STR_WAVEFORM_STYLE_DETAILED,
        @"oversampling_detailed_x2": STR_WAVEFORM_STYLE_DETAILED,
        @"oversampling_detailed_x4": STR_WAVEFORM_STYLE_DETAILED,
        @"oversampling_detailed_x8": STR_WAVEFORM_STYLE_DETAILED,
        @"three_band": STR_WAVEFORM_STYLE_THREE_BAND,
        @"spectrum": STR_WAVEFORM_STYLE_SPECTRUM,
        SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE: STR_WAVEFORM_STYLE_WIGGLE,
    };
    return names[identifier] ?: identifier;
}

// The Detailed family's Type chooser. Three keys, not one format string, so
// each reaches the translator in context. Detailed's own type is the style's
// name.
static inline NSString *VibeWaveformTypeDisplayName(NSString *identifier) {
    NSDictionary<NSString *, NSString *> *names = @{
        @"oversampling_detailed_x2": STR_WAVEFORM_TYPE_OVERSAMPLED_X2,
        @"oversampling_detailed_x4": STR_WAVEFORM_TYPE_OVERSAMPLED_X4,
        @"oversampling_detailed_x8": STR_WAVEFORM_TYPE_OVERSAMPLED_X8,
    };
    return names[identifier] ?: VibeWaveformStyleDisplayName(identifier);
}

// Every chooser's order: the styles by their localized names.
static inline NSArray<NSString *> *VibeWaveformStylesByDisplayName(NSArray<NSString *> *identifiers) {
    return [identifiers sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [VibeWaveformStyleDisplayName(a) localizedStandardCompare:VibeWaveformStyleDisplayName(b)];
    }];
}

NS_ASSUME_NONNULL_END
