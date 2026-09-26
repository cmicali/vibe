# Stress profiles and torture phases: what each weights, why, and what none can reach. Read when choosing a profile, adding an op kind, or judging what a clean run proved.

The weight tables are `PROFILES` in `scripts/stress.py` and `PHASES` in `scripts/torture.py`; this is the reasoning beside them.

## `stress.py` profiles

**`base`** mixes all command-only operations.

**`loading`** weights the open path and the async deliveries that race it (waveform, BPM, key, metadata landing after the track has changed), including `open_burst`: two to four opens on top of each other with no settle.

**`hammer`** is `loading` with the throttles off: `burst` moves the track-change loop inside the app, where a jump lands every main-queue turn, and `settle` drops to a token weight so an open almost never finishes before the next lands. Aim it at a big *local* library: every open is a real decode, tag parse and art extraction racing the next track change. Structural edits stay in the mix because a removal whose replacement play is still settling when the next open lands is a shape neither profile reaches alone.

**`ui`** loads no files: controller actions for transport, seeks, pitch, FX, layout and allowed menus against whatever is loaded. It does not test hit targets or event routing.

**`cloud`** puts the corpus behind the fake file provider, so an open *is* a download and the serial cloud lane, the foreground hold, the neighborhood re-ranking and the abandoned play/prefetch opens are all live at once. Rules:

- `set_fake_cloud` is armed before the first op — a run that spent its first batch on local files would score a different app — and re-armed mid-run by `cloud_churn`, sometimes under in-flight workers, which is the one thing here that could deadlock rather than misreport.
- `--cloud-percent` (default 60) leaves the rest local, which is what proves the cloud machinery has not slowed the local path.
- **Its weights are the inverse of `loading`'s.** Opens must be *sparing*: the sweep is deferred until playback starts or two seconds pass, and a replacement playlist drops the loader, so opens 80 ms apart mean the lane is never populated. Heavy `settle` (a sweep gets seconds), heavy `playlist_jump` (an arbitrary row moves the ranking and raises the hold where nothing prefetched), frequent `clear_caches` (a cache hit is no parse and so no download to race).
- **`capacity=1` is what makes it score anything.** Under the provider's unlimited default a background download never delays a foreground one, so the hold, the stand-aside and the lane ordering have nothing to be true about.
- Pair it with `make-cloud-corpus.py` (needs ffmpeg): **big folders** (against 19 files the sweep finishes instantly), **real tags and embedded art** (generated tones carry neither, and the worst bug here showed in the art path), a **mixture** with artless files, and **globally unique basenames** — the cloud trace records a transfer by last path component, so two same-named tracks are one file to any ordering assertion.

```bash
.claude/skills/vibe-stress/scripts/make-cloud-corpus.py --folders 12 --per-folder 40
make stress CORPUS=build/stress-corpus ARGS="--profile cloud --duration 2400 --iterations 100000"
```

**`theme`** drives the theme record end to end: store, sanitizer, apply. An apply is the app's widest single settings edit, so the profile weights **what is in flight underneath** it rather than the apply count: opens stay heavy, because the artwork color feeding the waveform palette rides the generation-matched install path and an apply landing between a delivery and its install is the case the color-ownership guarantee is written for; appearance flips are heavy because every theme rule branches on dark and a single-mode theme outranks `windowAppearanceStyle`. Its `theme_import` op is a **mutation** fuzzer, not a generator: a record built from scratch is refused at the JSON reader and never reaches the sanitizer, the one gate over four callers. It starts from a real dumped record and corrupts one to four fields with absurd numbers, wrong types, malformed colors and nonexistent font faces. **The nonexistent font face matters most, because it sanitizes clean** — a face name cannot be checked without asking the text system for it. `MAX_THEME_IMPORTS` caps imports because every accepted record is a *persisted* user theme.

**`playlist`** drives structural edits under enough transport to make them dangerous: the shell funnel owning the unload, the successor re-prefetch, the replacement play and the undo registration has no interesting branch unless something is playing. Opens stay in the mix: a replacement playlist is what makes a registered undo stale, reachable only by edit, open, undo.

**Expect `playlist` to fail at-rest mach ports on a long run, and pass `--ignore-metric machPorts` once you have checked that is the cause.** Its back-to-back reorders and undos strand row views in AppKit's `NSTableRowData._rowViewPurgatory` (`Playlist/Mac/CLAUDE.md`), each holding its cells and layers — about a hundred in ten minutes, growing the live heap and the resting port count together. Confirm with `heap <pid> | grep PlaylistRowView` after a `quiesce` (nonzero with an empty playlist) and `leaks --traceTree=<address> <pid>` ending in `_rowViewPurgatory` before standing the metric down; anything else growing is a new finding.

**Playlist editing needs no pointer or focus.** `select_rows all|none|<row|current> [row|current ...]` updates the actual table selection; row numbers outside the current list are ignored, so a list emptied by an earlier operation deselects. Numbered selections span the observed playlist, and `current` resolves inside the app at execution time, so a jump earlier in the batch still exercises current-row removal. `remove_selected` invokes the shell's existing selection-removal action, which owns transport and undo. Both work while the pane is closed or the window is inactive. Host-less tests drive the real `TransportKeyMonitor` handler for tap/hold, lost releases and Delete-repeat suppression without posting events. Native focus and table keyboard dispatch remain separate gesture tests.

**There is one reorder mechanism in stress.** `playlist_move` uses `reorder_begin` followed by update/drop/cancel, the same synthetic delegate path used for interleaved reorder operations. This exercises token matching, survivor resolution, slot arithmetic, table updates and shell undo without a native drag session. `file_drag_*` likewise remain direct delegate calls; despite their names they do not inject pointer events or export files to another app.

**`artwork`** aims at the folder-artwork fallback: opens through all three resolve strategies (a folder, a burst of files, a lone file), the playlist visible far more often so cell draws pull thumbnails off the resolver concurrently with the header's display-size load, and the setting flipped underneath both. Pair it with `make-hostile-corpus.py`: one cover per accepted filename, near-miss names, unreadable, undecodable and oversize covers, a cover that is a directory and one that is a FIFO, hard-linked real tracks mixed in so the run keeps changing between a file that decodes and one that cannot.

## Op kinds that exist for one reason

- `open_burst` — overlapping opens with no settle.
- `held_fx` — an effect enabled across a track change, sometimes left on until a later controller action.
- Out-of-range `seek` and `set_pitch` — the clamp escaping is the finding.
- `folder_art` — flips `set_folder_art`, the one change that drops every answer the resolver holds, onto resolves and decodes in flight. Emits `off`/`on` as a pair.
- `reorder_begin` / `reorder_finish` — opens a synthetic row-reorder drag and deliberately leaves it live so whatever the scheduler deals next (a replacing open, a removal, a convert, a burst) lands inside the session; `finish` later probes a slot and drops or cancels. That is the mid-drag race family (stale-drop rejection, a dragged row departing) no pointer can stage. A finish with no session live is a tolerated refusal. Reorder undo registrations feed the `undo` op's stack.
- `block_main` — `references/cloud-scenarios.md`.

**There is no `waveform_style` op, deliberately.** The style is a theme field, so a `click_menu waveform_style_*` answers "no menu item" — which the tolerated-error list swallowed, scoring a clean run over an op that did nothing. Its weight went to `theme`, which swaps the renderer anyway. A tolerated error over a dead op is the pattern to watch for when a menu moves.

## Unreachable from this driver

`--debug-cmd open` calls `NSURLUtil expandAndFilterList:` then `play:` directly, bypassing the burst coalescer and the open-request coordinator. `openBurstQueued` moves only under a real Launch Services open or the open panel; `openResultsBuffered` only under `file_drag_drop`, which routes through `MainWindow`'s drop path. **Do not read zeroes there as evidence those paths are clean.**

## `torture.py` phases

No settle anywhere. Seeded and replayable with `--seed`.

- `skip` — next/previous storm; each `next` is a full open.
- `seek` — including out-of-range and past-the-end values; escaping the clamp is the finding.
- `mixed` — skips, seeks, play/pause and the bar-based skip actions.
- `jump` — `play_index` anywhere. Adjacent tracks are the one case the successor prefetch has parked and the neighborhood ranking has reached; a jump lands where nothing has. Includes two jumps to the **same** row: same track, same URL, so only submission identity can drop the first's settlement.
- `blocked` — every op is `block_main <hold> <verb>`: main held, then a verb on the same turn, so worker callbacks from replaced tracks are parked behind a user action already underway.
- `boundary` — walking off the end repeatedly: the end-of-playlist park and `finishCurrentTrack`.

`--cloud SECONDS` arms the fake provider before opening the playlist, so every track change is a real transfer issued before the last one's download started — the shape the stress profiles cannot reach because they settle to let a sweep run. `--cloud-capacity` defaults to 1 for the same reason as the cloud profile.
