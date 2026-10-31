//
//  DebugStandardiOSVerbs.m
//  vibe-libs
//
//  The standard table's iOS verbs: the view tree, the screenshot, the frame
//  probe, and the clipboard.
//

#import "DebugStandardVerbs.h"

#if DEBUG

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "DebugCommandDispatch.h"
#import "DebugFrameProbe.h"
#import "DebugiOSCapture.h"
#import "DebugWireFormat.h"

NSArray<NSDictionary *> *VibeDebugStandardPlatformVerbs(VibeDebugStandardOptions *options) {
    return @[
        VibeDebugCmd(@"dump_view_tree", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            return VibeViewTreeDump();
        }),
        VibeDebugCmd(@"dump_screenshot", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            return VibeScreenshotJSON(commandId);
        }),
        // Frames the app is granted across a gesture, and how many ran
        // long. On a phone, start the probe with VibeDebugBeginFrameProbe(0)
        // and read the same report in the log every five seconds.
        VibeDebugCmd(@"sample_frame_rate <seconds>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            double seconds = 0;
            if (tokens.count < 2 || !VibeParseDouble(tokens[1], &seconds) || seconds <= 0 || seconds > 60) {
                return VibeErrorJSON(@"usage: sample_frame_rate <seconds (0-60)>");
            }
            VibeDebugBeginFrameProbe(seconds);
            return VibeJSONString(@{@"ok": @YES, @"seconds": @(seconds)});
        }),
        VibeDebugCmd(@"dump_frame_rate", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            return VibeJSONString(VibeDebugFrameProbeReport());
        }),
        // An app-owned clipboard item avoids the cross-app paste permission prompt.
        VibeDebugCmd(@"set_clipboard <text> | clear", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            if (tokens.count < 2) {
                return VibeErrorJSON(@"usage: set_clipboard <text> | clear");
            }
            NSString *text = VibeRestArgument(tokens);
            UIPasteboard.generalPasteboard.items = [text isEqualToString:@"clear"] ? @[] : @[@{
                UTTypeUTF8PlainText.identifier: text,
            }];
            return VibeJSONString(@{@"ok": @YES, @"changeCount": @(UIPasteboard.generalPasteboard.changeCount)});
        }),
    ];
}

#endif
