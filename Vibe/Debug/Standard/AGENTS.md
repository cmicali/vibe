# dev/DebugVerbs

The standard debug verbs: the ones that know nothing of the app, so every app's channel answers them the same way. They read the view tree, the menus, the screenshot, process health, and the build. They stall main on purpose, quit the app, and post synthetic input. It came from Vibe. It depends on `dev/DebugChannel`, for the table's shape and the wire, on `core/Graphics`, for the menu dump's image digest, and on `core/Common`. It builds on both platforms, with `Mac/` and `iOS/` halves.

| File | Owns |
| --- | --- |
| `DebugStandardVerbs.{h,m}` | `VibeDebugStandardOptions`, `VibeDebugStandardVerbs`, and the shared verbs |
| `DebugProcessHealth.{h,m}` | the process counters, the malloc counter, and the layer count, on both platforms |
| `Mac/DebugStandardMacVerbs.m` | the mac verbs of the standard table |
| `Mac/DebugViewTree.{h,m}` | the window and view tree, the menu dump, and the menu item search |
| `Mac/DebugScreenshot.{h,m}` | the in-process window render, and the notifyutil hook |
| `Mac/DebugSyntheticInput.{h,m}` | the input table, the key, mouse, drag, and scroll posting, the key-code map, and the modifier parser |
| `iOS/DebugStandardiOSVerbs.m` | the iOS verbs of the standard table |
| `iOS/DebugiOSCapture.{h,m}` | the key window, the view tree, and the screenshot |
| `iOS/DebugFrameProbe.{h,m}` | the display-link frame probe |

## The tables

| Table | Verbs |
| --- | --- |
| standard, shared | `dump_build`, `quit`, `work_tally`, `dump_health`, `block_main`, `block_main_deep` |
| standard, macOS | `dump_view_tree`, `dump_menu`, `click_menu`, `dump_screenshot`, `raise_window` |
| standard, iOS | `dump_view_tree`, `dump_screenshot`, `set_clipboard`, `sample_frame_rate`, `dump_frame_rate` |
| input, macOS | `key`, `key_down`, `key_up`, `click`, `mouse_down`, `mouse_up`, `mouse_move`, `drag`, `scroll` |

**`VibeDebugStandardVerbs(options)` answers the standard table**: the shared verbs, then the verbs for the platform it is built on. **`VibeDebugInputVerbs(options)` answers the input table**, on macOS. An app opts into it beside the standard table, so a later app can leave synthetic input out. The app builds each table once, at install, and adds it to the tables its dispatcher looks a verb up in. The unknown-command reply lists the same tables. The verbs' names, usages, waits, and reply keys are Vibe's, since its scripts and skills depend on them.

**TRAP: a verb in two tables runs from the first one, silently.** So an app keeps no verb of its own under a standard verb's name.

## The options

The options are blocks, so the piece holds no app type. Each block runs on main with the controller the app's dispatcher hands every handler. Every one is optional.

- **`dump_build`** replies `bundleId`, `executable`, `channel`, `version`, `git`, `built`, `pid`, and `path`, plus `buildExtras`. The eight keys win over an extra of the same name.
- **`dump_health`** replies `ok` and `process`, plus `healthExtras`. `VibeJSONString` sorts the keys, so an app that moved its own blocks into `healthExtras` keeps its reply byte-identical. Its wait is 10 s, since an app's extras may read a queue a wedge would hold.
- **`work_tally`** opens and closes `core/Common`'s work tally. The tally exists only where the app defines `VIBE_SIGNPOSTS`, so a build without it answers an error.
- **`block_main`** chains a verb from the shared verbs first, then from `chainableVerbs`. The platform verbs stay unchainable. It refuses itself and an unknown verb. It answers nil when the chained verb replies later.
- **The mouse verbs, `scroll`, and `raise_window`** aim at `targetWindow`. With no block, or a nil answer, they aim at `NSApp.mainWindow`. The key verbs post into the key window, or the target window when none is key.
- **`dump_screenshot`** renders the key window, then the main window, then the frontmost visible one. It ignores `targetWindow`.
- **`click_menu`** searches `NSApp.mainMenu` and calls `performMenuItem`. With no block, NSApp sends the item's action after the validation opening the menu would run. An app passes its own dispatch when a click should prove what a shortcut does.

## It compiles in every configuration and ships in none

**An app lists the template in every configuration.** Each `.m` wraps its body in `#if DEBUG`, so a release build compiles each to an empty object. The headers carry no `#if DEBUG`. So a call from release code compiles and then fails to link. An app keeps every caller under its own `#if DEBUG`.

## The input

**The input verbs post `NSEvent`s into the app's own event queue.** They run real event dispatch, local monitors included, and need no Accessibility permission. They are not containment. **The mouse verbs activate the app first**, since a non-key window swallows a first click. That takes focus from the frontmost app. A press on a draggable view can start a native drag. Tracking areas and hover effects never fire, since the window server drives them. The events run after the reply is written, so a caller polls the app's state for the result. Coordinates are content-view points with a top-left origin: `dump_screenshot`'s pixels divided by the backing scale.

**TRAP: a lone `mouse_down` on a control that runs a modal tracking loop stalls the app inside the loop.** The channel cannot deliver the `mouse_up` while it spins. `click` and `drag` queue every event before the loop starts.

**TRAP: an `NSEvent` made from a `CGEvent` has no window.** NSApp drops it. So `scroll` places its point to read as the window point and sends the event to the window directly.

An app's own verbs may call the posting functions, the key-code map, and the modifier parser, as a shortcut verb or a named gesture probe does.

## The screenshot

**The mac render runs in-process, with no window-server capture.** It needs no screen-recording permission, and it works with the display asleep or the window occluded. **TRAP: a glass view's layer renders as opaque white in `renderInContext:`.** So the render hides each `NSGlassEffectView`'s layer, uncommitted, over an appearance-matched fill. That forces a render of the model tree, so a glass-bearing window's animations land at their target values. A glass-free window renders the presentation tree mid-flight. Metal content does not render.

`VibeInstallDebugScreenshotHook` renders to a fixed path whenever its notification is posted, so a terminal can take a screenshot with `notifyutil -p`. `dump_screenshot` writes a file per command instead, under the channel's screenshot path.

The iOS render draws the key window's hierarchy. Blurs render only approximately. `simctl io booted screenshot` is the ground truth for pixels.

## Process health

The counters are for diffing between two readings of a run. None means much alone. **TRAP: a descriptor count lists the open descriptors, never the table's size.** The size grows with peak concurrency and never shrinks, so a burst of opens would read as a leak. iOS has no `libproc`, so it probes each slot of the table. The malloc counter keeps live allocations and the allocator's reservations apart. Under ASan or TSan it reads the sanitizer's own counts.

## The frame probe

On iOS, `sample_frame_rate` counts the frames the app is granted for a few seconds, and how many ran long. `dump_frame_rate` reads the report. `VibeDebugBeginFrameProbe(0)` runs the probe until it is replaced, and logs a report every five seconds. That is the road off a phone, whose console relays the log. An app starts it from a launch flag of its own.
