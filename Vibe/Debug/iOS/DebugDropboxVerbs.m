//
//  DebugDropboxVerbs.m
//  Vibe (iOS)
//
//  The Dropbox account, its mirror and the fake account (VibeFakeDropbox).
//

#import "DebugiOSEntry.h"

#if DEBUG

#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"
#import "AudioTrack.h"
#import "CloudFileMaterializer.h"
#import "DropboxMirror.h"
#import "VibeFakeDropbox.h"
#import "PlaceholderFiles.h"
#import "VibePlaylist.h"
#import "PlaybackController.h"
#import "RootViewController.h"
#import "RootViewController+Debug.h"

NSArray<NSDictionary *> *VibeDebugDropboxVerbs(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            // The Dropbox account and its mirror. The sign-in is Dropbox's own
            // web sheet, which neither the channel nor the driver can fill;
            // a human signs in, and this reads the result.
            VibeDebugCmd(@"dump_dropbox", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                DropboxMirror *mirror = DropboxMirror.shared;
                NSMutableDictionary *reply = [NSMutableDictionary dictionary];
                reply[@"linked"] = @(mirror.client.isLinked);
                reply[@"fake"] = @(VibeFakeDropbox.isInstalled);
                reply[@"accountID"] = mirror.client.accountID ?: NSNull.null;
                reply[@"accountName"] = mirror.client.accountName ?: NSNull.null;
                reply[@"accountPath"] = mirror.accountURL.path ?: NSNull.null;
                NSMutableArray *playlistInMirror = [NSMutableArray array];
                for (AudioTrack *track in controller.playback.playlist.tracks) {
                    if ([mirror containsURL:track.url]) {
                        // The transfer writing it now, as the handle reads it:
                        // windowBytes is the tail window held, readers the
                        // handles open on the part file.
                        CloudFileAvailability *stream = [mirror availabilityForURL:track.url];
                        [playlistInMirror addObject:@{
                            @"dropboxPath": [mirror dropboxPathForURL:track.url] ?: NSNull.null,
                            @"placeholder": @([PlaceholderFiles isRemotePlaceholderFile:track.url]),
                            @"stream": stream ? @{@"size": @(stream.size), @"writtenBytes": @(stream.writtenBytes),
                                                  @"windowBytes": @(stream.windowLength),
                                                  @"readers": @(stream.readerCount)} : NSNull.null,
                        }];
                    }
                }
                reply[@"playlistTracks"] = playlistInMirror;
                return VibeJSONString(reply);
            }),
            // A directory on disk answers as the account over the client's own
            // HTTP boundary (VibeFakeDropbox.h): no sign-in, no network. The
            // fixture is read by the app, so the simulator's host paths work.
            VibeDebugCmd(@"set_fake_dropbox <directory>|off [<transfer-seconds>]", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: set_fake_dropbox <directory>|off [<transfer-seconds>]");
                }
                DropboxClient *client = DropboxMirror.shared.client;
                if ([tokens[1] isEqualToString:@"off"]) {
                    [VibeFakeDropbox uninstallFromClient:client];
                    return VibeJSONString(@{@"ok": @YES, @"fake": @NO});
                }
                NSURL *directory = [NSURL fileURLWithPath:tokens[1] isDirectory:YES];
                BOOL isDirectory = NO;
                if (![NSFileManager.defaultManager fileExistsAtPath:directory.path isDirectory:&isDirectory]
                        || !isDirectory) {
                    return VibeErrorJSON(@"not a directory: %@", tokens[1]);
                }
                double seconds = 0;
                if (tokens.count > 2 && (!VibeParseDouble(tokens[2], &seconds) || seconds < 0)) {
                    return VibeErrorJSON(@"not a number of seconds: %@", tokens[2]);
                }
                [VibeFakeDropbox installWithDirectory:directory transferSeconds:seconds client:client];
                return VibeJSONString(@{@"ok": @YES, @"fake": @YES, @"directory": directory.path,
                                        @"transferSeconds": @(seconds)});
            }),
            VibeDebugCmd(@"dump_fake_dropbox", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                NSMutableDictionary *reply = [VibeFakeDropbox.statistics mutableCopy];
                reply[@"fake"] = @(VibeFakeDropbox.isInstalled);
                return VibeJSONString(reply);
            }),
            // One streaming road each (VibeFakeDropbox.h); file= scopes it to
            // a basename. Byte counts take K and M.
            VibeDebugCmd(@"fake_dropbox_fault <stall|drop|rev-change|throttle|expired-token|tail-fail|slow-tail|slow-tags|rate|latency|resume|clear> "
                         @"[file=<basename>] [after=<bytes>] [seconds=<s>] [rate=<bytes/s>]", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, RootViewController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: fake_dropbox_fault <kind|resume|clear> [file=<basename>] "
                                         @"[after=<bytes>] [seconds=<s>] [rate=<bytes/s>]");
                }
                NSString *kind = tokens[1];
                if ([kind isEqualToString:@"clear"]) {
                    [VibeFakeDropbox clearFaults];
                }
                else if ([kind isEqualToString:@"resume"]) {
                    [VibeFakeDropbox resumeStalls];
                }
                else {
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
                            return VibeErrorJSON(@"bad argument: %@", token);
                        }
                    }
                    if ([kind isEqualToString:@"rate"] && rate == 0) {
                        return VibeErrorJSON(@"rate needs rate=<bytes/s>");
                    }
                    if (![VibeFakeDropbox addFaultOfKind:kind file:file after:after seconds:seconds rate:rate]) {
                        return VibeErrorJSON(@"unknown fault: %@", kind);
                    }
                }
                return VibeJSONString(@{@"ok": @YES, @"faults": VibeFakeDropbox.statistics[@"faults"]});
            }),
        ];
    });
    return table;
}

#endif
