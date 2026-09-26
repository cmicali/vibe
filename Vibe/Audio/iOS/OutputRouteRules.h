//
//  OutputRouteRules.h
//  Vibe (iOS)
//
//  What the audio is coming out of, as the card's indicator draws it, and the
//  fold onto the coarser kind AudioSessionRecoveryRules.h decides with.
//
//  Two enums, one classification. The recovery rule only ever needed
//  none/built-in/external, and this is the finer answer the same scan already
//  produces; deriving one from the other is what stops the two from
//  disagreeing about what counts as external once a port kind is added.
//
//  The portType -> kind mapping is deliberately NOT here: the AVAudioSessionPort
//  constants are AVFoundation's API, and re-spelling their string values would
//  be depending on their contents. AudioSessionController.m owns it, which also
//  keeps this header — and the host-less suite that tests it — Foundation-only.
//

#import <Foundation/Foundation.h>

#import "AudioSessionRecoveryRules.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, VibeOutputRouteKind) {
    // No outputs at all: what an AVAudioSession that has never been activated
    // can report, so it means "nothing has claimed the output yet" rather
    // than "silence".
    VibeOutputRouteKindNone,
    VibeOutputRouteKindBuiltInSpeaker,
    VibeOutputRouteKindBuiltInReceiver,
    VibeOutputRouteKindWired,       // headphones, line out, USB audio
    VibeOutputRouteKindBluetooth,
    VibeOutputRouteKindAirPlay,
    VibeOutputRouteKindCarPlay,
    VibeOutputRouteKindOther,       // HDMI, AVB, DisplayPort, virtual
};

// The fold, and the whole reason the two enums cannot drift: an external kind
// folding to BuiltIn would fire the unplugged-headphones pause when AirPods
// connect.
static inline VibeAudioSessionOutputRouteKind
VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKind kind) {
    switch (kind) {
        case VibeOutputRouteKindNone:
            return VibeAudioSessionOutputRouteNone;
        case VibeOutputRouteKindBuiltInSpeaker:
        case VibeOutputRouteKindBuiltInReceiver:
            return VibeAudioSessionOutputRouteBuiltIn;
        case VibeOutputRouteKindWired:
        case VibeOutputRouteKindBluetooth:
        case VibeOutputRouteKindAirPlay:
        case VibeOutputRouteKindCarPlay:
        case VibeOutputRouteKindOther:
            return VibeAudioSessionOutputRouteExternal;
    }
}

// Default names keep the product name in English in every locale but move the
// possessive ("AirPods de Chris", "ChrisのAirPods", a German "#2" suffix), so the
// match is a substring anywhere, never an English pattern, and each probe runs
// before the one it contains. A renamed or unrecognised device draws "some
// external box", as every Bluetooth route did before the guess, and the name
// label beside it carries the truth — so the guess is never worse than that.
static inline NSString *VibeOutputRouteBluetoothSymbolName(NSString *_Nullable deviceName) {
    if ([deviceName containsString:@"AirPods Max"]) {
        return @"airpodsmax";
    }
    if ([deviceName containsString:@"AirPods Pro"]) {
        return @"airpodspro";
    }
    if ([deviceName containsString:@"AirPods"]) {
        return @"airpods";
    }
    if ([deviceName containsString:@"Beats"]) {
        return @"beats.headphones";
    }
    return @"hifispeaker.fill";
}

// The glyph the indicator draws. No default: in the switch, so a new kind is a
// build error rather than a blank corner.
//
// EVERY on-device route draws the AirPlay glyph, not a speaker: playing out of
// the phone is the state the control exists to change, so at rest it advertises
// what tapping it does rather than describing where the audio already is —
// Apple Music's rule. An unknown route draws it for the same reason. Only once
// the audio IS somewhere else does the glyph describe that somewhere, with the
// device's name beside it.
//
// Bluetooth is the one row that guesses, and it guesses from the user-renamable
// name because that is the only public signal: no audio, Bluetooth or accessory
// API says what the device is (docs/not-doing/rejected-alternatives.md).
static inline NSString *VibeOutputRouteSymbolName(VibeOutputRouteKind kind,
                                                  NSString *_Nullable deviceName) {
    switch (kind) {
        case VibeOutputRouteKindNone:
        case VibeOutputRouteKindBuiltInSpeaker:
        case VibeOutputRouteKindBuiltInReceiver:
        case VibeOutputRouteKindAirPlay:
            return @"airplayaudio";
        case VibeOutputRouteKindWired:
            return @"headphones";
        case VibeOutputRouteKindBluetooth:
            return VibeOutputRouteBluetoothSymbolName(deviceName);
        case VibeOutputRouteKindCarPlay:
            return @"car.fill";
        case VibeOutputRouteKindOther:
            return @"cable.connector";
    }
}

// The system's device name is drawn only where it says something the glyph does
// not — never for the phone's own speaker or receiver, and never when the name
// is missing or blank, which is what a route reported before the first
// activation looks like.
static inline BOOL VibeOutputRouteShowsDeviceName(VibeOutputRouteKind kind,
                                                  NSString *_Nullable deviceName) {
    if (deviceName.length == 0) {
        return NO;
    }
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    if ([deviceName stringByTrimmingCharactersInSet:whitespace].length == 0) {
        return NO;
    }
    switch (kind) {
        case VibeOutputRouteKindNone:
        case VibeOutputRouteKindBuiltInSpeaker:
        case VibeOutputRouteKindBuiltInReceiver:
            return NO;
        case VibeOutputRouteKindWired:
        case VibeOutputRouteKindBluetooth:
        case VibeOutputRouteKindAirPlay:
        case VibeOutputRouteKindCarPlay:
        case VibeOutputRouteKindOther:
            return YES;
    }
}

NS_ASSUME_NONNULL_END
