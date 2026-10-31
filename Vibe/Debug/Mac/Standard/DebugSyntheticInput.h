//
//  DebugSyntheticInput.h
//  vibe-libs
//
//  Synthesized key, mouse, drag, and scroll events, posted into the app's own
//  event queue. Each poster answers the verb's JSON reply.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <AppKit/AppKit.h>

@class VibeDebugStandardOptions;

NS_ASSUME_NONNULL_BEGIN

// The input table: key, key_down, key_up, click, mouse_down, mouse_up,
// mouse_move, drag, and scroll. An app opts into it beside the standard
// table. The mouse verbs and scroll aim at the options' targetWindow. The key
// verbs post into the key window, or the target window when none is key.
NSArray<NSDictionary *> *VibeDebugInputVerbs(VibeDebugStandardOptions *options);

// tokens[0] is the verb: key, key_down, or key_up. Posts into window.
NSString *VibeInjectKey(NSWindow *window, NSArray<NSString *> *tokens, BOOL down, BOOL up);

// tokens[0] is the verb: click, mouse_down, mouse_up, or mouse_move. Makes
// window key first.
NSString *VibeInjectMouse(NSWindow *window, NSArray<NSString *> *tokens);
NSString *VibeInjectDrag(NSWindow *window, NSArray<NSString *> *tokens);
NSString *VibeInjectScroll(NSWindow *window, NSArray<NSString *> *tokens);

// Activates the app and spins the run loop up to a second for window to
// become key. A non-key window swallows a first click.
void VibeMakeWindowKeyForInjection(NSWindow *window);

// Content-view points with a top-left origin, the frame dump_screenshot
// renders, to and from window points.
NSPoint VibeWindowPointForContentPoint(NSWindow *window, double x, double y);
NSPoint VibeContentPointForWindowPoint(NSWindow *window, NSPoint point);

// The ANSI key code for a key name the key verbs take, lowercased, or nil.
NSNumber *_Nullable VibeKeyCodeForName(NSString *name);

// The modifier names in tokens from start on, plus the repeat token. NO with
// *errorJSON set to the reply on an unknown name.
BOOL VibeParseModifiers(NSArray<NSString *> *tokens, NSUInteger start, NSEventModifierFlags *flags,
                        BOOL *repeat, NSString *_Nullable *_Nonnull errorJSON);

NS_ASSUME_NONNULL_END
