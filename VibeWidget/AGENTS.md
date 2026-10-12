# The widget extension

`VibeWidget` is the iOS widget extension. It has no engine, no playlist and no audio session, and it never reads an audio file. Everything it knows is the `VibeWidgetState` snapshot the app writes into the shared app group. The app side, including the snapshot and the buttons' intents, is `Vibe/iOS/Widget/AGENTS.md`.

The target compiles this directory plus `VibeWidgetState.{h,m}` and `VibeWidgetIntents.swift` from `Vibe/iOS/Widget/`. It links no app class. Both targets' entitlements must carry the app group, or `containerURL` is nil and the widget draws its empty state.

## Kinds and families

`VibeWidget.swift` declares four kinds of one widget type. The gallery shows each kind as its own page, so every small layout can sit on one Home Screen. The app's reload reaches all of them.

| Kind | Families |
| --- | --- |
| `VibeNowPlaying` | small, medium, and the three Lock Screen families |
| `VibeNowPlayingLarge` | large |
| `VibeNowPlayingWaveform` | small, the waveform tile |
| `VibeNowPlayingWaveformPlay` | small, the waveform tile with a play/pause disc |

**TRAP: a placed widget belongs to its kind.** The original kind keeps its small and medium because both shipped. Moving a size to another kind breaks every copy of it on someone's Home Screen.

`VibeWidgetView.swift` holds every layout. Its header describes each one. The Lock Screen families draw in the system's tint, so they use no artwork and only the played waveform image, as a shape.

## The timeline

A widget is not a live view. WidgetKit renders each entry once, ahead of time. A paused or empty state is one entry with policy `.never`, held until the app publishes again. A playing state steps the playhead to the track's end within 24 entries, never closer than 5 s apart.

**TRAP: the step is spread over what is left of the track.** A fixed step runs out on a long track, and the playhead then freezes. Ordinary playback publishes nothing, and `.atEnd` asks for a new timeline on WidgetKit's schedule, not the track's.

The extension has a hard memory cap. So the artwork and both waveform images are decoded once per timeline and shared by every entry. The blurred background is made once per timeline at 96 px, with one `CIContext` per process.

## Buttons and strings

The transport buttons and the waveform's seek zones are the intents in `Vibe/iOS/Widget/VibeWidgetIntents.swift`. They run in the app, not here. There are 16 seek zones. **TRAP: each zone is a button archived with every entry**, so more zones cost render time per entry. The Lock Screen strip has no seek zones.

**TRAP: strings resolve against the extension's own bundle.** `Localizable.xcstrings` here is the `widget.*` subset of the app's catalog, derived by `make strings`. Never edit it by hand. Every key the widget reads must start with `widget.`, which `extract-strings.sh` enforces. The display name and description are literals for the same reason the intent titles are, and each must match its `STR_WIDGET_*` entry.
