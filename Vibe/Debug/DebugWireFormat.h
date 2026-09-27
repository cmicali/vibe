//
//  DebugWireFormat.h
//  Vibe
//

#import <Foundation/Foundation.h>

#if DEBUG

// The channel's wire format: the notification name, the per-command file
// paths and the JSON reply serialization. Both apps' tables, the shared verbs
// and the mac CLI client must agree on it, so it is neither app's to own.

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
BOOL VibeParseNonnegativeInteger(NSString *token, NSUInteger *out);

// The mac table's spec for verb (Mac/DebugUtil.m). The client reads its
// clientTimeout, so its wait derives from the table the app dispatches with.
NSDictionary *VibeCommandSpecForVerb(NSString *verb);

#ifdef __cplusplus
}
#endif

#endif
