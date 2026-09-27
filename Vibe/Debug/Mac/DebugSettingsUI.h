//
//  DebugSettingsUI.h
//  Vibe
//

#import <Foundation/Foundation.h>

#if DEBUG

// The settings-window verbs. The injection verbs cannot reach this window —
// `click`, `drag` and the `key*` verbs all post to the main player window —
// and the panes are built in code with no view identifiers, leaving only
// coordinates that move with every localization and resize. So controls are
// addressed as the pane presents them, by the row's title or the control's
// own: dump_settings_ui lists the selected pane's controls, and
// settings_click activates one through its real action path.
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
