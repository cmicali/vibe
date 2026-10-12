//
//  DebugSettingsUI.h
//  Vibe
//

#import <Foundation/Foundation.h>

#if DEBUG

// Address Settings controls by row or control title. Coordinates vary with
// localization and window size. settings_click uses the real action path.
#ifdef __cplusplus
extern "C" {
#endif

// settings_open [pane [light|dark|system]]: shows the window, creating it on
// first use, and selects a pane by identifier, index or displayed title.
NSString *VibeDebugSettingsOpen(NSArray<NSString *> *tokens);

// settings_close: ends an attached sheet, then closes the window.
NSString *VibeDebugSettingsClose(void);

// dump_settings_ui: the pane list plus every control of the selected pane.
NSString *VibeDebugSettingsDump(void);

// settings_click <control> [value]: activates one control of the selected
// pane; see the usage text in the implementation for the per-kind values.
NSString *VibeDebugSettingsClick(NSArray<NSString *> *tokens);

// settings_reveal <control>: scrolls that control's card to the top of the
// pane and acts on nothing, so a screenshot reaches a long page's lower cards.
NSString *VibeDebugSettingsReveal(NSArray<NSString *> *tokens);

// settings_resize <width> <height>: a user resize by other means. Sets the
// content size (clamped to contentMinSize like a real drag), flushes layout,
// and replies with the settled frame, so a constraint snap-back is observable.
NSString *VibeDebugSettingsResize(NSArray<NSString *> *tokens);

// Run by the dispatcher after every verb, so a dump_settings_ui right after a
// store write reads the new state: the pane's own refresh triggers (appearing,
// window-key regain, menu-tracking end) never fire for a verb. No-op while the
// window is closed.
void VibeDebugSettingsRefreshSelectedPane(void);

#ifdef __cplusplus
}
#endif

#endif
