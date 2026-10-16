//
//  DebugLoadingVerbs.m
//  Vibe
//
//  The file-open path: cloud transfers, row loading, the loading
//  configuration, Open URL links and the fake cloud and HTTP server.
//

#import "DebugCommonVerbs.h"

#if DEBUG

#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"
#import "DebugChannel.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioFileMaterializationCoordinator+Debug.h"
#import "AudioLoadingConfiguration.h"
#import "AudioLoadingConfiguration+Debug.h"
#import "AudioTrackMetadataCache.h"
#import "AudioTrackMetadataCache+Debug.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Debug.h"
#import "AudioTrack.h"
#import "CloudFileMaterializer.h"
#import "CloudTransferRegistryInternal.h"
#import "LinkStore.h"
#import "PlaceholderFiles.h"
#import "PlaceholderFiles+Debug.h"
#import "RemotePlaceholderStoreInternal.h"
#import "VibeFakeCloud.h"
#import "VibeFakeHTTP.h"

// A VibeLinkError by its link.error key's last part. A script reads the
// failure the shell would show.
static NSString *VibeLinkErrorName(VibeLinkError code) {
    switch (code) {
        case VibeLinkErrorNone: return @"none";
        case VibeLinkErrorInvalid: return @"invalid";
        case VibeLinkErrorInsecure: return @"insecure";
        case VibeLinkErrorUnreachable: return @"unreachable";
        case VibeLinkErrorLocalNetwork: return @"local_network";
        case VibeLinkErrorNotFound: return @"not_found";
        case VibeLinkErrorDenied: return @"denied";
        case VibeLinkErrorNotAudio: return @"not_audio";
        case VibeLinkErrorNoSize: return @"no_size";
        case VibeLinkErrorLiveStream: return @"live_stream";
        case VibeLinkErrorServer: return @"server";
        case VibeLinkErrorCancelled: return @"cancelled";
        case VibeLinkErrorICloudPrivate: return @"icloud_private";
        case VibeLinkErrorICloudFolder: return @"icloud_folder";
        case VibeLinkErrorICloudUnreadable: return @"icloud_unreadable";
    }
    return @"unknown";
}

static NSDictionary *VibeOpenLinkReply(NSURL *file, NSError *error) {
    if (file) {
        return @{@"ok": @YES, @"file": file.path, @"placeholder": @([PlaceholderFiles isRemotePlaceholderFile:file])};
    }
    BOOL linkError = [error.domain isEqualToString:VibeLinkErrorDomain];
    NSError *cause = error.userInfo[NSUnderlyingErrorKey];
    return @{
        @"ok": @NO,
        @"linkError": linkError ? VibeLinkErrorName((VibeLinkError)error.code) : [NSString stringWithFormat:@"%@ %ld",
                                                                        error.domain, (long)error.code],
        @"code": @(error.code),
        @"status": error.userInfo[VibeHTTPErrorStatusCodeKey] ?: NSNull.null,
        @"cause": cause ? [NSString stringWithFormat:@"%@ %ld", cause.domain, (long)cause.code] : NSNull.null,
    };
}

// Each link's directory under the Links root, with its record and its file:
// a placeholder or a download, and the stream writing it now.
static NSArray<NSDictionary *> *VibeLinkDirectories(LinkStore *store) {
    NSMutableArray<NSDictionary *> *links = [NSMutableArray array];
    NSFileManager *files = NSFileManager.defaultManager;
    NSArray<NSURL *> *directories = [files contentsOfDirectoryAtURL:store.rootURL includingPropertiesForKeys:nil
                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                              error:NULL];
    for (NSURL *directory in [directories sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent compare:b.lastPathComponent];
    }]) {
        NSURL *file = [files contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil
                                              options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL].firstObject;
        CloudFileAvailability *stream = file ? [store availabilityForURL:file] : nil;
        BOOL placeholder = file && [PlaceholderFiles isRemotePlaceholderFile:file];
        [links addObject:@{
            @"directory": directory.lastPathComponent,
            @"record": [store indexOfDirectory:directory] ?: NSNull.null,
            @"file": file.lastPathComponent ?: NSNull.null,
            @"path": file.path ?: NSNull.null,
            @"placeholder": @(placeholder),
            @"stream": stream ? @{@"size": @(stream.size), @"writtenBytes": @(stream.writtenBytes),
                                  @"windowBytes": @(stream.windowLength), @"readers": @(stream.readerCount)}
                              : NSNull.null,
        }];
    }
    return links;
}

NSArray<NSDictionary *> *VibeDebugLoadingVerbs(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            // The cloud lane's at-rest facts, both zero once a sweep settles.
            // macOS also reports them in dump_health; this is iOS's only view.
            VibeDebugCmd(@"set_loading <off | indeterminate | fraction>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                // Both indicator modes, without a real slow cloud open.
                NSString *arg = tokens.count > 1 ? tokens[1].lowercaseString : @"";
                double fraction = -1;
                if ([arg isEqualToString:@"off"]) {
                    [surface debugSetWaveformLoading:NO fraction:-1];
                    return VibeJSONString(@{@"ok": @YES, @"loading": @"off"});
                }
                if (![arg isEqualToString:@"indeterminate"] && !VibeParseDouble(arg, &fraction)) {
                    return VibeErrorJSON(@"usage: set_loading <off | indeterminate | 0..1>");
                }
                [surface debugSetWaveformLoading:YES fraction:(float)fraction];
                return VibeJSONString(@{@"ok": @YES, @"fraction": @(fraction)});
            }),
            VibeDebugCmd(@"dump_cloud_health", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                AudioTrackMetadataCache *cache = surface.debugMetadataCache;
                return VibeJSONString(@{
                    @"cloudParsesPending": @([cache debugPendingBackgroundMaterializationCount]),
                    @"cloudLaneHeld": @([cache debugBackgroundMaterializationHeld] ? 1 : 0),
                    @"priorityLane": [cache debugPriorityLaneState],
                    @"scanLane": [cache debugScanLaneState],
                    @"materialization":
                            [AudioFileMaterializationCoordinator.sharedCoordinator debugState],
                });
            }),
            VibeDebugCmd(@"dump_row_loading", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                // Both halves of the row-loading guarantee, so a mismatch
                // shows: the registry's transfers and the rows it would mark.
                CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
                NSDictionary<NSString *, NSNumber *> *snapshot = [registry transferSnapshot];
                NSMutableArray *transfers = [NSMutableArray arrayWithCapacity:snapshot.count];
                [snapshot enumerateKeysAndObjectsUsingBlock:^(NSString *path,
                        NSNumber *progress, BOOL *stop) {
                    [transfers addObject:@{
                        @"file": path.lastPathComponent,
                        @"progress": progress,
                    }];
                }];
                NSMutableArray *rows = [NSMutableArray array];
                NSUInteger count = surface.debugPlaylistCount;
                for (NSUInteger index = 0; index < count; index++) {
                    AudioTrack *track = [surface debugPlaylistTrackAtIndex:index];
                    if (!track.url || ![registry isTransferringURL:track.url]) {
                        continue;
                    }
                    [rows addObject:@{
                        @"index": @(index),
                        @"file": track.url.lastPathComponent ?: @"",
                        @"progress": @([registry progressForURL:track.url]),
                    }];
                }
                return VibeJSONString(@{
                    @"transfers": transfers,
                    @"loadingRows": rows,
                    @"playlistCount": @(count),
                });
            }),
            VibeDebugCmd(@"dump_audio_loading", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                AudioLoadingConfiguration *materialization =
                        AudioFileMaterializationCoordinator.sharedCoordinator.currentConfiguration;
                AudioLoadingConfiguration *player = surface.debugPlayer.loadingConfiguration;
                AudioLoadingConfiguration *metadata = surface.debugMetadataCache.loadingConfiguration;
                return VibeJSONString([AudioLoadingConfiguration
                        debugConsumerDictionaryWithMaterialization:materialization
                                                           player:player
                                                         metadata:metadata]);
            }),
            VibeDebugCmd(@"set_audio_loading <defaults | key=value ...>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: set_audio_loading <defaults | key=value ...>");
                }
                AudioLoadingConfiguration *current = AudioFileMaterializationCoordinator
                        .sharedCoordinator.currentConfiguration;
                NSError *error = nil;
                NSArray<NSString *> *arguments = [tokens subarrayWithRange:
                        NSMakeRange(1, tokens.count - 1)];
                AudioLoadingConfiguration *configuration = [AudioLoadingConfiguration
                        debugConfigurationByApplyingArguments:arguments
                        toConfiguration:current error:&error];
                if (!configuration) {
                    return VibeErrorJSON(@"%@", error.localizedDescription);
                }
                [surface.debugPlayer applyLoadingConfiguration:configuration];
                [surface.debugMetadataCache applyLoadingConfiguration:configuration];
                [AudioFileMaterializationCoordinator.sharedCoordinator
                        applyConfiguration:configuration];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"configuration": configuration.debugDictionary,
                    @"appliesTo": @"new admissions, loaders, prefetch decisions, and opens",
                });
            }),
            // Each shell's Open URL road: the resolve, then the file through
            // the shell's replace. Replies when the resolve settles, with the
            // file or the link's failure, never waiting for playback.
            VibeDebugCmd(@"open_url <url>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                           id<VibeDebugPlayerSurface> surface) {
                if (tokens.count != 2) {
                    return VibeErrorJSON(@"usage: open_url <url>");
                }
                [surface debugOpenLink:tokens[1] completion:^(NSURL *file, NSError *error) {
                    VibeWriteDebugResponse(commandId, VibeJSONString(VibeOpenLinkReply(file, error)));
                }];
                return nil; // response written by the completion above
            }),
            VibeDebugCmd(@"dump_links", 10, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                        id<VibeDebugPlayerSurface> surface) {
                LinkStore *store = LinkStore.shared;
                [store measureDownloadsWithCompletion:^(long long bytes) {
                    VibeWriteDebugResponse(commandId, VibeJSONString(@{
                        @"root": store.rootURL.path,
                        @"budgetBytes": @(store.downloadBudget),
                        @"downloadsBytes": @(bytes),
                        @"links": VibeLinkDirectories(store),
                    }));
                }];
                return nil; // response written by the completion above
            }),
            // A directory serves as https://fake.vibe.test/ and
            // http://fake.local/ under the Links client (VibeFakeHTTP.h).
            VibeDebugCmd(@"set_fake_http <directory>|off [<transfer-seconds>]", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                if (tokens.count < 2 || tokens.count > 3) {
                    return VibeErrorJSON(@"usage: set_fake_http <directory>|off [<transfer-seconds>]");
                }
                HTTPTransferClient *client = LinkStore.shared.client;
                if ([tokens[1] isEqualToString:@"off"]) {
                    [VibeFakeHTTP uninstallFromClient:client];
                    return VibeJSONString(@{@"ok": @YES, @"fake": @NO});
                }
                BOOL isDirectory = NO;
                if (![NSFileManager.defaultManager fileExistsAtPath:tokens[1] isDirectory:&isDirectory]
                        || !isDirectory) {
                    return VibeErrorJSON(@"not a directory: %@", tokens[1]);
                }
                double seconds = 0;
                if (tokens.count > 2 && (!VibeParseDouble(tokens[2], &seconds) || seconds < 0)) {
                    return VibeErrorJSON(@"not a number of seconds: %@", tokens[2]);
                }
                [VibeFakeHTTP installWithDirectory:[NSURL fileURLWithPath:tokens[1] isDirectory:YES]
                                   transferSeconds:seconds client:client];
                return VibeJSONString(@{@"ok": @YES, @"fake": @YES, @"directory": tokens[1],
                                        @"transferSeconds": @(seconds),
                                        @"hosts": @[@"https://fake.vibe.test/", @"http://fake.local/"]});
            }),
            VibeDebugCmd(@"dump_fake_http", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                           id<VibeDebugPlayerSurface> surface) {
                return VibeJSONString(VibeFakeHTTP.statistics);
            }),
            // The value is the kind's own: drop, etag-change, and stall take
            // bytes (after=), rate bytes per second, latency and expiry
            // seconds, status a code. Byte counts take K and M.
            VibeDebugCmd(@"fake_http_fault <stall|drop|etag-change|rate|latency|no-range|no-length|icy|status|html"
                         @"|gzip|expiry|off> [<value>] [file=<basename>] [after=<bytes>] [once|always]", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: fake_http_fault <kind|off> [<value>] [file=<basename>] "
                                         @"[after=<bytes>] [once|always]");
                }
                NSString *kind = tokens[1];
                if ([kind isEqualToString:@"off"]) {
                    [VibeFakeHTTP clearFaults];
                    return VibeJSONString(@{@"ok": @YES, @"faults": VibeFakeHTTP.statistics[@"faults"]});
                }
                NSString *file = nil;
                NSNumber *once = nil;
                // Past the 256 KB readable mark by default. The stream has begun there.
                uint64_t after = 512 * 1024, rate = 0;
                double seconds = 1, number = 0;
                NSInteger status = 0;
                for (NSUInteger i = 2; i < tokens.count; i++) {
                    NSString *token = tokens[i];
                    if (i == 2 && [token rangeOfString:@"="].location == NSNotFound
                            && ![@[@"once", @"always"] containsObject:token]) {
                        BOOL valid = NO;
                        if ([kind isEqualToString:@"rate"]) {
                            valid = VibeParseByteCount(token, &rate) && rate > 0;
                        }
                        else if ([kind isEqualToString:@"latency"] || [kind isEqualToString:@"expiry"]) {
                            valid = VibeParseDouble(token, &seconds) && seconds >= 0;
                        }
                        else if ([kind isEqualToString:@"status"]) {
                            valid = VibeParseDouble(token, &number) && number >= 100 && number < 600;
                            status = (NSInteger)number;
                        }
                        else {
                            valid = VibeParseByteCount(token, &after);
                        }
                        if (!valid) {
                            return VibeErrorJSON(@"bad value for %@: %@", kind, token);
                        }
                    }
                    else if ([token hasPrefix:@"file="] && token.length > 5) {
                        file = [token substringFromIndex:5];
                    }
                    else if ([token hasPrefix:@"after="]) {
                        if (!VibeParseByteCount([token substringFromIndex:6], &after)) {
                            return VibeErrorJSON(@"bad argument: %@", token);
                        }
                    }
                    else if ([token isEqualToString:@"once"] || [token isEqualToString:@"always"]) {
                        once = @([token isEqualToString:@"once"]);
                    }
                    else {
                        return VibeErrorJSON(@"bad argument: %@", token);
                    }
                }
                if (![VibeFakeHTTP addFaultOfKind:kind file:file after:after seconds:seconds rate:rate
                                           status:status once:once]) {
                    return VibeErrorJSON(@"unknown fault, or its value missing: %@", kind);
                }
                return VibeJSONString(@{@"ok": @YES, @"faults": VibeFakeHTTP.statistics[@"faults"]});
            }),
            // See VibeFakeCloud.h for the modes. Seconds of 0 uninstalls.
            VibeDebugCmd(@"set_fake_cloud <seconds> [<percent>] [capacity=N] [uniform] "
                         @"[progress=none|linear|sparse|stall] [sticky] "
                         @"[fail=<basename>]", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                double seconds = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &seconds) || seconds < 0) {
                    return VibeErrorJSON(@"usage: set_fake_cloud <seconds> [<percent>] [options]");
                }
                if (seconds == 0) {
                    [VibeFakeCloud uninstall];
                    return VibeJSONString([VibeFakeCloud statistics]);
                }
                double percent = 100;
                NSUInteger firstOption = 2;
                if (tokens.count > 2 && VibeParseDouble(tokens[2], &percent)) {
                    if (percent < 0 || percent > 100) {
                        return VibeErrorJSON(@"percent must be 0-100");
                    }
                    firstOption = 3;
                }
                else {
                    percent = 100;
                }
                static NSDictionary<NSString *, NSNumber *> *progressModes;
                static dispatch_once_t modesOnce;
                dispatch_once(&modesOnce, ^{
                    progressModes = @{@"none": @(VibeFakeCloudProgressNone),
                                      @"linear": @(VibeFakeCloudProgressLinear),
                                      @"sparse": @(VibeFakeCloudProgressSparse),
                                      @"stall": @(VibeFakeCloudProgressStall)};
                });
                // Validated before the install re-arms, so a rejected command
                // leaves the previous install untouched.
                BOOL sticky = NO, uniform = NO, hasCapacity = NO;
                NSUInteger capacity = 0;
                NSNumber *progressMode = nil;
                NSString *failingBasename = nil;
                for (NSUInteger i = firstOption; i < tokens.count; i++) {
                    NSString *option = tokens[i];
                    if ([option isEqualToString:@"sticky"]) {
                        sticky = YES;
                    }
                    else if ([option isEqualToString:@"uniform"]) {
                        uniform = YES;
                    }
                    else if ([option hasPrefix:@"capacity="]) {
                        if (!VibeParseNonnegativeInteger(
                                [option substringFromIndex:9], &capacity)) {
                            return VibeErrorJSON(@"capacity must be a non-negative integer");
                        }
                        hasCapacity = YES;
                    }
                    else if ([option hasPrefix:@"fail="]) {
                        failingBasename = [option substringFromIndex:5];
                        if (failingBasename.length == 0) {
                            return VibeErrorJSON(@"fail= needs a basename");
                        }
                    }
                    else if ([option hasPrefix:@"progress="]) {
                        progressMode = progressModes[[option substringFromIndex:9]];
                        if (!progressMode) {
                            return VibeErrorJSON(@"progress must be none, linear, sparse, or stall");
                        }
                    }
                    else {
                        return VibeErrorJSON(@"unknown option '%@'", option);
                    }
                }
                [VibeFakeCloud installWithTransferSeconds:seconds
                                          datalessPercent:(NSUInteger)percent];
                if (sticky) {
                    [VibeFakeCloud setStickyDataless:YES];
                }
                if (uniform) {
                    [VibeFakeCloud setUniformDurations:YES];
                }
                if (hasCapacity) {
                    [VibeFakeCloud setTransferCapacity:capacity];
                }
                if (progressMode) {
                    [VibeFakeCloud setProgressMode:
                            (VibeFakeCloudProgressMode)progressMode.integerValue];
                }
                if (failingBasename) {
                    [VibeFakeCloud setFailingBasename:failingBasename];
                }
                return VibeJSONString([VibeFakeCloud statistics]);
            }),
            VibeDebugCmd(@"dump_cloud_trace", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                return VibeJSONString(@{@"stats": [VibeFakeCloud statistics],
                                        @"events": [VibeFakeCloud traceEvents]});
            }),
            VibeDebugCmd(@"clear_cloud_trace", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                [VibeFakeCloud clearTrace];
                return VibeJSONString(@{@"ok": @YES});
            }),
            // See PlaceholderFiles+Debug.h.
            VibeDebugCmd(@"set_dataless_diag <on|off>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                if (tokens.count < 2 || (![tokens[1] isEqualToString:@"on"]
                        && ![tokens[1] isEqualToString:@"off"])) {
                    return VibeErrorJSON(@"usage: set_dataless_diag <on|off>");
                }
                [PlaceholderFiles setDatalessDiagnosticsEnabled:[tokens[1] isEqualToString:@"on"]];
                return VibeJSONString(@{@"ok": @YES});
            }),
            VibeDebugCmd(@"dump_dataless_diag", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                return VibeJSONString([PlaceholderFiles datalessDiagnostics]);
            }),
        ];
    });
    return table;
}

#endif
