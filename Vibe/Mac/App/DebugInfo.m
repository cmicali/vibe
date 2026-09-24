//
//  DebugInfo.m
//  Vibe
//

#import "DebugInfo.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AppStats.h"
#import "AudioDevice.h"
#import "AudioDeviceManager.h"
#import "AudioFX.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Devices.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "CoreAudioUtil.h"
#import "FolderAccessManager.h"
#import "MainPlayerController.h"
#import "NSBundle+BuildInfo.h"
#import "PlaylistController.h"
#import <OSLog/OSLog.h>
#import <sys/sysctl.h>

static NSString *const kVibeLogSubsystem = @"com.commonwealthrecordings.Vibe";

// A bound on the file, not a filter: a long session keeps its newest lines.
static const NSUInteger kVibeDebugInfoMaxLogLines = 100000;

// Long enough for any setting a person typed; a theme archive or other blob
// stored as a string is cut rather than filling the report.
static const NSUInteger kVibeDebugInfoMaxStringLength = 2000;

static NSString *VibeSysctlString(const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) {
        return nil;
    }
    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    if (sysctlbyname(name, buffer.mutableBytes, &size, NULL, 0) != 0) {
        return nil;
    }
    return [NSString stringWithUTF8String:buffer.bytes];
}

static BOOL VibeRunningTranslated(void) {
    int translated = 0;
    size_t size = sizeof(translated);
    return sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0) == 0 && translated == 1;
}

static NSString *VibeThermalStateName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal:  return @"nominal";
        case NSProcessInfoThermalStateFair:     return @"fair";
        case NSProcessInfoThermalStateSerious:  return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
    }
    return @"unknown";
}

static NSString *VibeGrantedFolderStateName(VibeGrantedFolderState state) {
    switch (state) {
        case VibeGrantedFolderStateActive:      return @"active";
        case VibeGrantedFolderStateRestoring:   return @"restoring";
        case VibeGrantedFolderStateUnavailable: return @"unavailable";
    }
    return @"unknown";
}

// A stored setting made printable. Data goes by size — bookmarks and theme
// images are opaque, and a bookmark would put an access grant in a file meant
// for sharing.
static id VibeJSONSafe(id value) {
    if ([value isKindOfClass:NSData.class]) {
        return [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)[(NSData *)value length]];
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *string = value;
        return string.length <= kVibeDebugInfoMaxStringLength ? string
                : [NSString stringWithFormat:@"%@… (%lu characters)",
                   [string substringToIndex:kVibeDebugInfoMaxStringLength], (unsigned long)string.length];
    }
    if ([value isKindOfClass:NSNumber.class]) {
        return value;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *safe = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
            safe[[key description]] = VibeJSONSafe(object);
        }];
        return safe;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *safe = [NSMutableArray array];
        for (id object in (NSArray *)value) {
            [safe addObject:VibeJSONSafe(object)];
        }
        return safe;
    }
    return [value description] ?: @"";
}

static NSDictionary *VibeAppDictionary(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSDate *launched = NSRunningApplication.currentApplication.launchDate;
    return @{
        @"version": bundle.vibeVersionString ?: @"",
        @"git": bundle.vibeGitString ?: @"",
#if DEBUG
        @"configuration": @"Debug",
#else
        @"configuration": @"Release",
#endif
#if defined(__arm64__)
        @"architecture": @"arm64",
#else
        @"architecture": @"x86_64",
#endif
        @"translated": @(VibeRunningTranslated()),
        @"bundlePath": bundle.bundlePath ?: @"",
        @"launched": launched.description ?: @"",
        @"runningSeconds": @(launched ? (NSInteger)-launched.timeIntervalSinceNow : 0),
        @"verboseLogging": @((BOOL)VIBE_VERBOSE_LOGGING),
        @"exclusiveOutputBuilt": @((BOOL)VIBE_ENABLE_EXCLUSIVE_OUTPUT),
    };
}

static NSDictionary *VibeSystemDictionary(void) {
    NSProcessInfo *process = NSProcessInfo.processInfo;
    return @{
        @"macOS": process.operatingSystemVersionString ?: @"",
        @"model": VibeSysctlString("hw.model") ?: @"",
        @"cpu": VibeSysctlString("machdep.cpu.brand_string") ?: @"",
        @"memoryGB": @(process.physicalMemory / (1024 * 1024 * 1024)),
        @"thermalState": VibeThermalStateName(process.thermalState),
        @"lowPowerMode": @(process.lowPowerModeEnabled),
        @"appLanguage": NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"",
        @"preferredLanguages": NSLocale.preferredLanguages ?: @[],
        @"locale": NSLocale.currentLocale.localeIdentifier ?: @"",
        @"timeZone": NSTimeZone.localTimeZone.name ?: @"",
    };
}

static NSDictionary *VibePlayerDictionary(MainPlayerController *controller) {
    AudioPlayer *player = controller.audioPlayer;
    NSMutableDictionary *d = [@{
        @"state": player.isPlaying ? @"playing" : player.isPaused ? @"paused" : @"stopped",
        @"loading": @(player.isLoading),
        @"position": @(player.position),
        @"duration": @(player.duration),
        @"outputAudioActive": @(player.outputAudioActive),
        @"gaplessArmed": @(player.isGaplessArmed),
        @"crossfadeMilliseconds": @(player.crossfadeMilliseconds),
        @"declick": @(player.declick),
        @"pitch": @(player.pitch),
        @"requestedOutputDeviceId": @(player.currentlyRequestedAudioDeviceId),
        @"bitPerfect": player.bitPerfectReportDictionary,
    } mutableCopy];
    AudioFX *fx = player.fx;
    if (fx) {
        d[@"fx"] = @{
            @"lowKill": @(fx.lowKillEnabled),
            @"reverbSend": @(fx.reverbSendEnabled),
            @"delaySend": @(fx.delaySendEnabled),
            @"shortDelaySend": @(fx.shortDelaySendEnabled),
        };
    }
    AudioTrack *track = player.currentTrack;
    if (track) {
        AudioTrackMetadata *metadata = track.metadata;
        d[@"track"] = @{
            @"path": track.url.path ?: @"",
            @"fileType": metadata.fileType ?: @"",
            @"sampleRate": metadata.sampleRate ?: @0,
            @"bitrate": metadata.bitrate ?: @0,
            @"duration": @(metadata.duration),
        };
    }
    PlaylistController *playlist = controller.playlistController;
    d[@"playlist"] = @{
        @"count": @(playlist.playlist.count),
        @"currentIndex": @(playlist.currentIndex),
    };
    return d;
}

// Which windows are up is often the answer — #47's freeze needed Settings open.
static NSArray *VibeWindowsArray(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible) {
            continue;
        }
        [windows addObject:@{
            @"class": NSStringFromClass(window.class),
            @"frame": NSStringFromRect(window.frame),
            @"key": @(window.isKeyWindow),
            @"onScreen": @((BOOL)((window.occlusionState & NSWindowOcclusionStateVisible) != 0)),
        }];
    }
    return windows;
}

NSDictionary<NSString *, id> *VibeDebugInfoSnapshot(MainPlayerController *controller) {
    NSMutableArray *folders = [NSMutableArray array];
    for (VibeGrantedFolder *folder in FolderAccessManager.sharedInstance.grantedFolders) {
        [folders addObject:@{@"path": folder.path ?: @"", @"state": VibeGrantedFolderStateName(folder.state)}];
    }
    AppStats *stats = AppStats.sharedInstance;
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults
            persistentDomainForName:NSBundle.mainBundle.bundleIdentifier] ?: @{};
    return @{
        @"app": VibeAppDictionary(),
        @"system": VibeSystemDictionary(),
        @"player": VibePlayerDictionary(controller),
        @"windows": VibeWindowsArray(),
        @"grantedFolders": folders,
        @"stats": @{
            @"filesOpened": @(stats.totalFilesOpened),
            @"foldersOpened": @(stats.totalFoldersOpened),
            @"secondsPlayed": @(stats.totalSecondsPlayed),
        },
        @"settingsAtDefaults": @(AppSettings.sharedInstance.allSettingsAtDefaults),
        // Everything stored, not a curated list, so a setting added later is
        // reported without anyone remembering to add it here.
        @"settings": VibeJSONSafe(stored),
    };
}

static NSString *VibeLogLevelName(OSLogEntryLogLevel level) {
    switch (level) {
        case OSLogEntryLogLevelUndefined: return @"-";
        case OSLogEntryLogLevelDebug:     return @"D";
        case OSLogEntryLogLevelInfo:      return @"I";
        case OSLogEntryLogLevelNotice:    return @"N";
        case OSLogEntryLogLevelError:     return @"E";
        case OSLogEntryLogLevelFault:     return @"F";
    }
    return @"?";
}

// This process's entries: all of Vibe's own, the audio frameworks' (device and
// engine trouble is reported there, not by us), and anyone's errors. What
// exists depends on VIBE_VERBOSE_LOGGING — without it Vibe's info and debug
// were never stored.
static NSArray<NSString *> *VibeLogLines(NSUInteger *dropped) {
    *dropped = 0;
    NSError *error = nil;
    OSLogStore *store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:&error];
    OSLogEnumerator *entries = store ? [store entriesEnumeratorWithOptions:0 position:nil
                                                                  predicate:nil error:&error] : nil;
    if (!entries) {
        return @[[NSString stringWithFormat:@"(the log could not be read: %@)", error.localizedDescription]];
    }
    NSDateFormatter *time = [[NSDateFormatter alloc] init];
    time.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    time.dateFormat = @"HH:mm:ss.SSS";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (OSLogEntry *entry in entries) {
        if (![entry isKindOfClass:OSLogEntryLog.class]) {
            continue;
        }
        OSLogEntryLog *log = (OSLogEntryLog *)entry;
        BOOL ours = [log.subsystem isEqualToString:kVibeLogSubsystem];
        BOOL audio = [log.subsystem hasPrefix:@"com.apple.coreaudio"] || [log.subsystem hasPrefix:@"com.apple.audio"]
                || [log.subsystem hasPrefix:@"com.apple.avfaudio"];
        if (!ours && !audio && log.level < OSLogEntryLogLevelError) {
            continue;
        }
        NSString *source = ours ? log.category
                : [NSString stringWithFormat:@"%@:%@", log.subsystem.length ? log.subsystem : log.sender, log.category];
        [lines addObject:[NSString stringWithFormat:@"%@ %@ [%@] %@", [time stringFromDate:log.date],
                          VibeLogLevelName(log.level), source, log.composedMessage]];
        if (lines.count >= 2 * kVibeDebugInfoMaxLogLines) {
            [lines removeObjectsInRange:NSMakeRange(0, kVibeDebugInfoMaxLogLines)];
            *dropped += kVibeDebugInfoMaxLogLines;
        }
    }
    if (lines.count > kVibeDebugInfoMaxLogLines) {
        NSUInteger excess = lines.count - kVibeDebugInfoMaxLogLines;
        [lines removeObjectsInRange:NSMakeRange(0, excess)];
        *dropped += excess;
    }
    return lines;
}

// One outstanding worker per section, even after timeout. A hung driver must
// not accumulate more workers each time the user saves another report.
static NSDictionary *VibeFreshDiagnosticSection(NSString *section, NSDictionary *(^read)(void)) {
    static NSMutableDictionary *completed, *inFlight;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        completed = [NSMutableDictionary dictionary];
        inFlight = [NSMutableDictionary dictionary];
    });
    NSTimeInterval requestedAt = NSDate.date.timeIntervalSince1970;
    dispatch_group_t group;
    @synchronized (completed) {
        group = inFlight[section];
        if (!group) {
            group = dispatch_group_create();
            dispatch_group_enter(group);
            inFlight[section] = group;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSDictionary *value;
                @try {
                    NSDictionary *snapshot = read() ?: @{};
                    value = @{@"status": @"fresh", @"capturedAt": @(NSDate.date.timeIntervalSince1970),
                              @"value": snapshot};
                } @catch (NSException *exception) {
                    value = @{@"status": @"failed", @"error": exception.reason ?: @"exception"};
                }
                @synchronized (completed) {
                    completed[section] = value;
                    [inFlight removeObjectForKey:section];
                }
                dispatch_group_leave(group);
            });
        }
    }
    BOOL timedOut = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0;
    @synchronized (completed) {
        NSMutableDictionary *result = [completed[section] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (timedOut) result[@"status"] = result[@"value"] ? @"timed out; cached" : @"timed out; unavailable";
        result[@"requestedAt"] = @(requestedAt);
        return result;
    }
}

NSString *VibeDebugInfoText(NSDictionary<NSString *, id> *snapshot, AudioPlayer *player) {
    NSMutableDictionary *report = [snapshot mutableCopy];
    NSUInteger dropped = 0;
    NSArray<NSString *> *log = VibeLogLines(&dropped);
    NSDictionary *hardware = VibeFreshDiagnosticSection(@"hardware", ^NSDictionary *{
        NSMutableArray *devices = [NSMutableArray array];
        for (AudioDevice *device in AudioDeviceManager.sharedInstance.cachedOutputDevices) {
            NSMutableDictionary *d = [[CoreAudioUtil diagnosticDescriptionOfDeviceID:(AudioDeviceID)device.deviceId] mutableCopy];
            d[@"systemDefault"] = @(device.isSystemDefault);
            [devices addObject:d];
        }
        return @{@"devices": devices, @"systemDefaultOutputDeviceId": @([CoreAudioUtil systemDefaultOutputDeviceID])};
    });
    NSDictionary *playback = VibeFreshDiagnosticSection(@"player", ^NSDictionary *{
        return player.outputDeviceDiagnosticSnapshot;
    });
    report[@"freshDiagnostics"] = @{@"hardware": hardware, @"player": playback};
    report[@"outputDevices"] = hardware[@"value"][@"devices"] ?: @[];
    NSMutableDictionary *playerInfo = [report[@"player"] mutableCopy];
    if (playback[@"value"]) [playerInfo addEntriesFromDictionary:playback[@"value"]];
    playerInfo[@"systemDefaultOutputDeviceId"] = hardware[@"value"][@"systemDefaultOutputDeviceId"] ?: NSNull.null;
    report[@"player"] = playerInfo;

    NSData *json = [NSJSONSerialization dataWithJSONObject:report
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
              error:NULL];
    NSISO8601DateFormatter *stamp = [[NSISO8601DateFormatter alloc] init];
    stamp.timeZone = NSTimeZone.localTimeZone;
    NSMutableString *text = [NSMutableString stringWithFormat:@"Vibe debug info, saved %@\n\n",
                             [stamp stringFromDate:NSDate.date]];
    [text appendString:json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]
                            : @"(the state could not be encoded)"];
    [text appendFormat:@"\n\n=== Log, this run: %lu lines%@ ===\n", (unsigned long)log.count,
     dropped ? [NSString stringWithFormat:@", %lu older lines dropped", (unsigned long)dropped] : @""];
    [text appendString:[log componentsJoinedByString:@"\n"]];
    [text appendString:@"\n"];
    return text;
}
