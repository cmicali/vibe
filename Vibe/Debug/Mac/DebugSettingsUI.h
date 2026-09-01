//
//  DebugSettingsUI.h
//  Vibe
//

#import <Foundation/Foundation.h>

#if DEBUG

// The settings-window verbs of the debug command channel: settings_open,
// settings_close, dump_settings_ui and settings_click. They exist because the
// generic injection verbs cannot reach this window — `click`, `drag` and the
// `key*` verbs all post into the MAIN player window's event stream — and
// because the panes are built in code with no view identifiers, so there is
// nothing for a caller to aim at but coordinates that move with every
// localization and every pane resize.
//
// So this addresses controls the way the pane presents them: by the row's
// title or the control's own. dump_settings_ui lists what the
// selected pane holds and settings_click activates one of those by name,
// through the control's real action path.
//
// Same C-linkage guard rationale as DebugUtil.h.
#ifdef __cplusplus
extern "C" {
#endif

// settings_open [pane]: shows the window, creating it on first use, and
// selects a pane by identifier, index or displayed title.
NSString *VibeDebugSettingsOpen(NSArray<NSString *> *tokens);

// settings_close: ends an attached sheet, then closes the window.
NSString *VibeDebugSettingsClose(void);

// dump_settings_ui: the pane list plus every control of the selected pane.
NSString *VibeDebugSettingsDump(void);

// settings_click <control> [value]: activates one control of the selected
// pane; see the usage text in the implementation for the per-kind values.
NSString *VibeDebugSettingsClick(NSArray<NSString *> *tokens);

// settings_resize <width> <height> — a user resize by other means: sets the
// settings window's frame (content points, clamped to contentMinSize like a
// real drag), flushes layout, and replies with the SETTLED frame — which is
// what makes a constraint snap-back observable from a test.
NSString *VibeDebugSettingsResize(NSArray<NSString *> *tokens);

// Run by the dispatch funnel after every verb: re-runs the selected pane's
// refresh so a dump_settings_ui right after a store write reads the new
// state. The pane's own refresh triggers are all user gestures —
// appearance, window-key regain, menu-tracking end — none of which a verb
// fires. No-op while the window is closed; an unappeared pane refreshes on
// its next viewWillAppear anyway.
void VibeDebugSettingsRefreshSelectedPane(void);

#ifdef __cplusplus
}
#endif

#endif
