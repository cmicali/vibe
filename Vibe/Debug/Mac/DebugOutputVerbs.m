//
//  DebugOutputVerbs.m
//  Vibe
//
//  The output device and its bit-perfect mode.
//

#import "DebugInternal.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "MainPlayerController+Settings.h"
#import "AudioDevice.h"
#import "AudioDeviceManager.h"
#import "OutputDevicesMenuController.h"

#if DEBUG

// Applied once the submitted selection settles: the mode setters write the
// SAVED device's mode, so applying one before the bind lands would name the
// device being left (the pane disables both switches while pending for the
// same reason). Retried on main rather than waited for, since the settlement
// needs this thread. Gives up after `attempts`; the reply has already told the
// caller to confirm with dump_state.
static void VibeApplyOutputModesWhenSelectionSettles(MainPlayerController *controller,
                                                     NSNumber *bitPerfect,
                                                     NSNumber *exclusive,
                                                     NSInteger attempts) {
    if (attempts <= 0) {
        // Logged: a dropped mode looks exactly like one never asked for.
        LogWarn(@"set_output_device: gave up waiting for the selection to settle; "
                @"bit-perfect=%@ exclusive=%@ NOT applied",
                bitPerfect ?: @"-", exclusive ?: @"-");
        return;
    }
    if (controller.devicesMenuController.outputDeviceSelectionPending) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VibeApplyOutputModesWhenSelectionSettles(controller, bitPerfect, exclusive, attempts - 1);
        });
        return;
    }
    if (bitPerfect) {
        AppSettings.sharedInstance.bitPerfectOutput = bitPerfect.boolValue;
    }
    if (exclusive) {
        AppSettings.sharedInstance.exclusiveOutput = exclusive.boolValue;
    }
    [controller applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfectApply];
    LogWarn(@"set_output_device: applied bit-perfect=%@ exclusive=%@ after selection settled",
            bitPerfect ?: @"-", exclusive ?: @"-");
}

NSArray<NSDictionary *> *VibeDebugOutputVerbs(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            // By UID, not HAL device id, which an unplug and replug can
            // change; UID is also what AppSettings keys per-device modes by.
            // Name is the fallback, in resolveOutputDeviceForUID:name:'s
            // order, because a human can type a name but not a UID.
            //
            // The modes are only requested here (see
            // VibeApplyOutputModesWhenSelectionSettles); confirm with
            // dump_state.player.bitPerfect.
            VibeDebugCmd(@"set_output_device <uid|name|system> [<bit-perfect on|off> [<exclusive on|off>]]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count < 2 || tokens.count > 4) {
                    return VibeErrorJSON(@"usage: set_output_device <uid|name|system> [<bit-perfect on|off> [<exclusive on|off>]]");
                }
                NSString *wanted = tokens[1];
                NSInteger deviceId = -1;
                AudioDevice *match = nil;
                if (![wanted.lowercaseString isEqualToString:@"system"]) {
                    NSArray<AudioDevice *> *devices = [AudioDeviceManager.sharedInstance outputDevices];
                    for (AudioDevice *device in devices) {
                        if ([device.uid isEqualToString:wanted]) {
                            match = device;
                            break;
                        }
                    }
                    if (!match) {
                        for (AudioDevice *device in devices) {
                            if ([device.name isEqualToString:wanted]) {
                                match = device;
                                break;
                            }
                        }
                    }
                    if (!match) {
                        NSMutableArray<NSString *> *known = [NSMutableArray array];
                        for (AudioDevice *device in devices) {
                            [known addObject:device.name ?: @""];
                        }
                        return VibeErrorJSON(@"no output device with UID or name '%@' (known: %@)",
                                             wanted, [known componentsJoinedByString:@", "]);
                    }
                    deviceId = match.deviceId;
                }
                [controller.devicesMenuController selectOutputDevice:deviceId];

                NSNumber *bitPerfect = nil, *exclusive = nil;
                BOOL parsed = NO;
                if (tokens.count >= 3) {
                    NSArray<NSString *> *pair = @[tokens[0], tokens[2]];
                    if (!VibeParseOnOff(pair, &parsed)) {
                        return VibeErrorJSON(@"bit-perfect argument must be on or off");
                    }
                    bitPerfect = @(parsed);
                }
                if (tokens.count == 4) {
                    NSArray<NSString *> *pair = @[tokens[0], tokens[3]];
                    if (!VibeParseOnOff(pair, &parsed)) {
                        return VibeErrorJSON(@"exclusive argument must be on or off");
                    }
                    exclusive = @(parsed);
                }
                if (bitPerfect || exclusive) {
                    VibeApplyOutputModesWhenSelectionSettles(controller, bitPerfect, exclusive, 600);
                }
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"deviceId": @(deviceId),
                    @"uid": match.uid ?: @"",
                    @"name": match.name ?: @"System Output",
                    @"selectionPending": @(controller.devicesMenuController.outputDeviceSelectionPending),
                    @"modesRequested": @(bitPerfect != nil || exclusive != nil),
                });
            }),
            VibeDebugCmd(@"set_saved_output_device <uid> <name>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                if (tokens.count != 3) {
                    return VibeErrorJSON(@"usage: set_saved_output_device <uid> <name>");
                }
                // Next-launch input only; exercise missing-device restoration
                // without changing the live binding or editing container prefs.
                AppSettings.sharedInstance.audioOutputDeviceUID = tokens[1];
                AppSettings.sharedInstance.audioOutputDeviceName = tokens[2];
                return VibeJSONString(@{@"ok": @YES});
            }),
            VibeDebugCmd(@"set_bit_perfect <on|off>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                // The pane's toggle minus its eligibility gate: forcing the
                // mode on over an ineligible device, the report reads off,
                // which is what a test of that gate wants. Like the pane it
                // writes the SAVED device's mode, and System Output, with no
                // UID to remember it under, answers off.
                BOOL on;
                if (!VibeParseOnOff(tokens, &on)) {
                    return VibeErrorJSON(@"usage: set_bit_perfect <on|off>");
                }
                if (controller.devicesMenuController.outputDeviceSelectionPending) {
                    return VibeErrorJSON(@"output device selection is still pending");
                }
                AppSettings.sharedInstance.bitPerfectOutput = on;
                [controller applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfectApply];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"bitPerfectOutput": @(AppSettings.sharedInstance.bitPerfectOutput),
                });
            }),
        ];
    });
    return table;
}

#endif
