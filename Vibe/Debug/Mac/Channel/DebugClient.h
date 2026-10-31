//
//  DebugClient.h
//  vibe-libs
//
//  The CLI client: the channel's other end, on macOS. An app's binary is its
//  own client. Its main() routes the client flag here before
//  NSApplicationMain, so no second instance of the app starts. The client
//  shares the app's bundle identifier and sandbox container, so it writes the
//  command file into the same tmp the app drains.
//
//      .../App.app/Contents/MacOS/App --debug-cmd dump_build
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VibeDebugClientOptions : NSObject
// The name the app installed the channel under. Default: the bundle identifier.
@property (nonatomic, copy) NSString *channel;
// The app's name, in usage and no-reply lines. Default: the process name.
@property (nonatomic, copy) NSString *displayName;
// Before every stderr line, as "<prefix>: ". Default: the process name.
@property (nonatomic, copy) NSString *messagePrefix;
// An environment variable that replaces the default wait. Nil: none.
@property (nonatomic, copy, nullable) NSString *timeoutEnvironmentKey;
// A verb's wait, read from the app's tables. 0: the default, 5 s.
@property (nonatomic, copy, nullable) NSTimeInterval (^waitForVerb)(NSString *verb);
// Verbs whose reply's "path" is a file the client reads and removes: its
// bytes go to stdout under "-", and as base64 in a script's reply line.
// Default: none.
@property (nonatomic, copy) NSArray<NSString *> *fileVerbs;
// A verb the client runs in its own process. Answers its exit code, or -1
// when it is no local verb. print writes a reply as the client does.
@property (nonatomic, copy, nullable) int (^localVerb)(NSArray<NSString *> *args, BOOL inScript,
                                                       void (^print)(NSString *json));
@end

// argv[1] is the app's client flag, and the rest is the command. Answers the
// exit code: 0 ok, 1 no reply, 2 an error reply, 64 usage.
//
// The client runs two verbs itself. `sleep <seconds>` pauses a script.
// `script <file | ->` runs one command per line and prints one compact JSON
// reply per command, as NDJSON. Blank lines and full-line # comments are
// skipped, and quotes group a token. A script stops at its first failing
// command and answers that command's exit code.
int VibeDebugClientMain(int argc, const char *_Nonnull argv[_Nonnull], VibeDebugClientOptions *options);

NS_ASSUME_NONNULL_END
