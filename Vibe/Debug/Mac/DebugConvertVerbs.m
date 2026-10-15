//
//  DebugConvertVerbs.m
//  Vibe
//
//  Convert to FLAC, and the undo and redo that reverse it.
//

#import "DebugInternal.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioTrackMetadata.h"
#import "FLACConvertRules.h"

#if DEBUG

#import "AudioTrack.h"

// The file moves of a conversion and of Move to Trash settle after the undo
// manager call returns, so the reply waits on the controller's one-shot settled
// hook rather than racing the Trash; a reply outliving the client's timeout
// writes one orphan response and cannot fire on a later menu-driven undo. An
// undo that moves no file settles inside the call and never fires the hook, so
// the post-call check answers it.
static NSString *VibeRunUndoRedoCommand(NSString *commandId, MainPlayerController *controller, BOOL redo) {
    NSUndoManager *undoManager = controller.window.undoManager;
    if (controller.isFileMoveInFlight) {
        return VibeErrorJSON(@"a file move is still in progress");
    }
    if (redo ? !undoManager.canRedo : !undoManager.canUndo) {
        return VibeErrorJSON(redo ? @"nothing to redo" : @"nothing to undo");
    }
    NSString *actionName = redo ? undoManager.redoActionName : undoManager.undoActionName;
    void (^settled)(BOOL, NSString *) = ^(BOOL committed, NSString *reason) {
        NSMutableDictionary *response = [@{
            @"ok": @YES,
            (redo ? @"redid" : @"undid"): actionName ?: @"",
            @"committed": @(committed),
            @"canUndo": @(undoManager.canUndo),
            @"canRedo": @(undoManager.canRedo),
        } mutableCopy];
        if (reason) {
            response[@"reason"] = reason;
        }
        VibeWriteDebugResponse(commandId, VibeJSONString(response));
    };
    controller.undoRedoSettledHandler = settled;
    if (redo) {
        [controller redo:nil];
    }
    else {
        [controller undo:nil];
    }
    // The hook clears itself as it fires. Still installed with no file move
    // in flight means this undo moved no file: reply now.
    if (controller.undoRedoSettledHandler
            && !controller.isFileMoveInFlight) {
        controller.undoRedoSettledHandler = nil;
        settled(YES, nil);
    }
    return nil; // response written by the settled block
}

NSArray<NSDictionary *> *VibeDebugConvertVerbs(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            // The whole Convert to FLAC path on the current track, swap and
            // disposal included. keep|delete writes Move Original to Trash
            // After Conversion, as the menu item does, and leaves it written.
            // omit-trash-url is a one-shot fault for the ambiguous successful
            // Trash result, armed only once the command will convert.
            VibeDebugCmd(@"convert_to_flac [keep|delete] [omit-trash-url]", 120, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSString *mode = tokens.count > 1 ? tokens[1].lowercaseString : nil;
                NSString *fault = tokens.count > 2 ? tokens[2].lowercaseString : nil;
                BOOL omitTrashURL = [fault isEqualToString:@"omit-trash-url"];
                if (tokens.count > 3 ||
                        (mode && !([mode isEqualToString:@"keep"] || [mode isEqualToString:@"delete"])) ||
                        (fault && !omitTrashURL) ||
                        (omitTrashURL && ![mode isEqualToString:@"delete"])) {
                    return VibeErrorJSON(@"usage: convert_to_flac [keep|delete] [omit-trash-url]");
                }
                AudioTrack *track = controller.playlistController.currentTrack;
                if (!track) {
                    return VibeErrorJSON(@"no track to convert");
                }
                // Refuse before touching the one-shot fault: clearing or arming
                // it while an earlier conversion runs would change that
                // request's undo record. Mirroring the converter's synchronous
                // refusals also keeps an unaccepted request from leaving a
                // fault for some later conversion.
                if (controller.fileConverter.isConverting) {
                    return VibeErrorJSON(@"conversion already in progress");
                }
                if (!track.url.isFileURL ||
                        !VibeTrackIsConvertibleToFLAC(track.metadata.fileType,
                                                     track.url.pathExtension)) {
                    return VibeErrorJSON(@"current track is not convertible to FLAC");
                }
                if (mode) {
                    AppSettings.sharedInstance.deleteOriginalAfterConvert = [mode isEqualToString:@"delete"];
                }
                [controller.fileConverter debugClearPendingSourceTrashURLFault];
                id faultOwner = nil;
                if (omitTrashURL) {
                    faultOwner = [controller.fileConverter debugArmOmitNextSourceTrashURL];
                }
                // Read before the swap replaces the track; reported back so a
                // test can assert the deletion without reading the Trash,
                // which TCC denies a terminal.
                NSString *sourcePath = track.url.path;
                [controller convertTrackToFLAC:track
                                    completion:^(NSURL *outputURL, BOOL sourceDeleted, NSError *error) {
                    // Source disposal normally consumes the fault; cancel it
                    // only if this request's is still pending after a failure.
                    if (faultOwner) {
                        [controller.fileConverter
                                debugCancelPendingSourceTrashURLFaultWithOwner:faultOwner];
                    }
                    if (!outputURL) {
                        VibeWriteDebugResponse(commandId,
                                VibeErrorJSON(@"convert failed: %@", error.localizedDescription));
                        return;
                    }
                    AudioTrack *swapped = [controller.playlistController trackForURL:outputURL];
                    // The completion runs after the disposal settles, so this
                    // stat is a verdict, not a race.
                    BOOL sourceRemains = [NSFileManager.defaultManager fileExistsAtPath:sourcePath];
                    VibeWriteDebugResponse(commandId, VibeJSONString(@{
                        @"ok": @YES,
                        @"output": outputURL.path,
                        @"row": @([controller.playlistController getIndexForTrack:swapped]),
                        @"source": sourcePath ?: @"",
                        @"sourceDeleted": @(sourceDeleted),
                        @"sourceRemains": @(sourceRemains),
                    }));
                }];
                return nil; // response written by the completion above
            }),
            VibeDebugCmd(@"undo", 30, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeRunUndoRedoCommand(commandId, controller, NO);
            }),
            VibeDebugCmd(@"redo", 30, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                return VibeRunUndoRedoCommand(commandId, controller, YES);
            }),
        ];
    });
    return table;
}

#endif
