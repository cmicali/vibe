//
//  DebugWireFormat.h
//  vibe-libs
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <Foundation/Foundation.h>

// The channel's wire format: the notification name, the per-command file
// paths and the JSON reply serialization. The app's tables and its client
// must agree on it, so the channel owns it.

#ifdef __cplusplus
extern "C" {
#endif

extern NSString *const kVibeDebugCommandNotification;

NSString *VibeDebugTmpPath(NSString *name);
NSString *VibeDebugCommandPath(NSString *commandId);
NSString *VibeDebugResponsePath(NSString *commandId);
NSString *VibeDebugScreenshotPathForCommand(NSString *commandId);

NSString *VibeJSONString(NSDictionary *dict);
NSString *VibeErrorJSON(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

BOOL VibeParseDouble(NSString *token, double *out);
// A byte count, with a K or M suffix for KiB or MiB.
BOOL VibeParseByteCount(NSString *token, uint64_t *bytes);

#ifdef __cplusplus
}
#endif
