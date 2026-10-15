//
//  DebugAccountVerbs.m
//  Vibe (iOS)
//
//  The accounts, their mirrors and their fakes (VibeFakeDropbox,
//  VibeFakeGoogleDrive).
//

#import "DebugiOSEntry.h"

#if DEBUG

#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"
#import "AudioTrack.h"
#import "CloudFileMaterializer.h"
#import "DropboxMirror.h"
#import "GoogleDriveMirror.h"
#import "VibeFakeDropbox.h"
#import "VibeFakeGoogleDrive.h"
#import "PlaceholderFiles.h"
#import "Playlist.h"
#import "PlaybackController.h"
#import "RootViewController.h"
#import "RootViewController+Debug.h"

// A fake fault's arguments past its kind: file=<basename>, after=<bytes>,
// seconds=<s>, rate=<bytes/s>. Byte counts take K and M. Nil, with the
// error JSON, for a bad one.
static NSDictionary *VibeParseFaultArguments(NSArray<NSString *> *tokens, NSString *kind, NSString **error) {
    NSString *file = nil;
    // Past the 256 KB readable mark by default, so the stream has begun.
    uint64_t after = 512 * 1024, rate = 0;
    double seconds = [kind hasPrefix:@"slow-"] ? 5 : 1;
    for (NSString *token in [tokens subarrayWithRange:NSMakeRange(2, tokens.count - 2)]) {
        NSRange equals = [token rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound ? token : [token substringToIndex:equals.location];
        NSString *value = equals.location == NSNotFound ? @"" : [token substringFromIndex:equals.location + 1];
        double number = 0;
        BOOL valid = YES;
        if ([key isEqualToString:@"file"] && value.length > 0) {
            file = value;
        }
        else if ([key isEqualToString:@"after"]) {
            valid = VibeParseByteCount(value, &after);
        }
        else if ([key isEqualToString:@"rate"]) {
            valid = VibeParseByteCount(value, &rate) && rate > 0;
        }
        else if ([key isEqualToString:@"seconds"]) {
            valid = VibeParseDouble(value, &number) && number >= 0;
            seconds = number;
        }
        else {
            valid = NO;
        }
        if (!valid) {
            *error = VibeErrorJSON(@"bad argument: %@", token);
            return nil;
        }
    }
    if ([kind isEqualToString:@"rate"] && rate == 0) {
        *error = VibeErrorJSON(@"rate needs rate=<bytes/s>");
        return nil;
    }
    NSMutableDictionary *arguments = [@{@"after": @(after), @"seconds": @(seconds), @"rate": @(rate)} mutableCopy];
    arguments[@"file"] = file;
    return arguments;
}

// A fake's fixture directory, and its pace: nil, with the error JSON, for a
// bad one.
static NSURL *VibeParseFakeDirectory(NSArray<NSString *> *tokens, double *seconds, NSString **error) {
    NSURL *directory = [NSURL fileURLWithPath:tokens[1] isDirectory:YES];
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:directory.path isDirectory:&isDirectory] || !isDirectory) {
        *error = VibeErrorJSON(@"not a directory: %@", tokens[1]);
        return nil;
    }
    *seconds = 0;
    if (tokens.count > 2 && (!VibeParseDouble(tokens[2], seconds) || *seconds < 0)) {
        *error = VibeErrorJSON(@"not a number of seconds: %@", tokens[2]);
        return nil;
    }
    return directory;
}

// An account's state and the playlist's tracks in its mirror: each track's
// identity on the service, whether it is a placeholder, and the transfer
// writing it now, as the handle reads it. windowBytes is the tail window
// held, readers the handles open on the part file.
static NSDictionary *VibeAccountDump(AccountMirror *mirror, BOOL fake, RootViewController *controller) {
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    reply[@"linked"] = @(mirror.client.isLinked);
    reply[@"fake"] = @(fake);
    reply[@"accountID"] = mirror.client.accountID ?: NSNull.null;
    reply[@"accountName"] = mirror.client.accountName ?: NSNull.null;
    reply[@"accountPath"] = mirror.accountURL.path ?: NSNull.null;
    NSMutableArray *playlistInMirror = [NSMutableArray array];
    for (AudioTrack *track in controller.playback.playlist.tracks) {
        if ([mirror containsURL:track.url]) {
            CloudFileAvailability *stream = [mirror availabilityForURL:track.url];
            [playlistInMirror addObject:@{
                @"remote": [mirror identityOfURL:track.url] ?: NSNull.null,
                @"placeholder": @([PlaceholderFiles isRemotePlaceholderFile:track.url]),
                @"stream": stream ? @{@"size": @(stream.size), @"writtenBytes": @(stream.writtenBytes),
                                      @"windowBytes": @(stream.windowLength),
                                      @"readers": @(stream.readerCount)} : NSNull.null,
            }];
        }
    }
    reply[@"playlistTracks"] = playlistInMirror;
    return reply;
}

// One account's verbs: dump_<slug> reads the account, set_fake_<slug> makes
// a directory on disk the account over the client's own HTTP boundary (no
// sign-in, no network; the app reads the fixture, so the simulator's host
// paths work), dump_fake_<slug> reads the fake, and fake_<slug>_fault scripts
// one streaming road with file= scoping it to a basename. The real sign-in
// is the service's web sheet, which only a human fills.
static NSArray<NSDictionary *> *VibeAccountVerbs(NSString *slug, AccountMirror *mirror, Class fake, NSString *kinds) {
    NSString *setUsage = [NSString stringWithFormat:@"set_fake_%@ <directory>|off [<transfer-seconds>]", slug];
    NSString *faultArguments = @"[file=<basename>] [after=<bytes>] [seconds=<s>] [rate=<bytes/s>]";
    return @[
        VibeDebugCmd([NSString stringWithFormat:@"dump_%@", slug], 0,
                     ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
            return VibeJSONString(VibeAccountDump(mirror, [fake isInstalled], controller));
        }),
        VibeDebugCmd(setUsage, 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
            if (tokens.count < 2) {
                return VibeErrorJSON(@"usage: %@", setUsage);
            }
            if ([tokens[1] isEqualToString:@"off"]) {
                [fake uninstallFromClient:mirror.client];
                return VibeJSONString(@{@"ok": @YES, @"fake": @NO});
            }
            double seconds = 0;
            NSString *error = nil;
            NSURL *directory = VibeParseFakeDirectory(tokens, &seconds, &error);
            if (!directory) {
                return error;
            }
            [fake installWithDirectory:directory transferSeconds:seconds client:mirror.client];
            return VibeJSONString(@{@"ok": @YES, @"fake": @YES, @"directory": directory.path,
                                    @"transferSeconds": @(seconds)});
        }),
        VibeDebugCmd([NSString stringWithFormat:@"dump_fake_%@", slug], 0,
                     ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
            NSMutableDictionary *reply = [[fake statistics] mutableCopy];
            reply[@"fake"] = @([fake isInstalled]);
            return VibeJSONString(reply);
        }),
        VibeDebugCmd([NSString stringWithFormat:@"fake_%@_fault <%@> %@", slug, kinds, faultArguments], 0,
                     ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
            if (tokens.count < 2) {
                return VibeErrorJSON(@"usage: fake_%@_fault <%@> %@", slug, kinds, faultArguments);
            }
            NSString *kind = tokens[1];
            if ([kind isEqualToString:@"clear"]) {
                [fake clearFaults];
            }
            else if ([kind isEqualToString:@"resume"] && [fake respondsToSelector:@selector(resumeStalls)]) {
                [fake resumeStalls];
            }
            else {
                NSString *error = nil;
                NSDictionary *arguments = VibeParseFaultArguments(tokens, kind, &error);
                if (!arguments) {
                    return error;
                }
                if (![fake addFaultOfKind:kind file:arguments[@"file"]
                                    after:[arguments[@"after"] unsignedLongLongValue]
                                  seconds:[arguments[@"seconds"] doubleValue]
                                     rate:[arguments[@"rate"] unsignedLongLongValue]]) {
                    return VibeErrorJSON(@"unknown fault: %@", kind);
                }
            }
            return VibeJSONString(@{@"ok": @YES, @"faults": [fake statistics][@"faults"]});
        }),
    ];
}

NSArray<NSDictionary *> *VibeDebugAccountVerbs(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Each fake's kinds are in its header.
        table = [VibeAccountVerbs(@"dropbox", DropboxMirror.shared, VibeFakeDropbox.class,
                                  @"stall|drop|rev-change|throttle|expired-token|tail-fail|slow-tail|slow-tags|rate|latency|resume|clear")
                 arrayByAddingObjectsFromArray:
                 VibeAccountVerbs(@"google_drive", GoogleDriveMirror.shared, VibeFakeGoogleDrive.class,
                                  @"stall|drop|version-change|throttle|expired-token|rate|latency|clear")];
    });
    return table;
}

#endif
