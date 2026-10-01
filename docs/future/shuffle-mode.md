# Future: Shuffle mode

**Status: planned, not implemented (verified 2026-09-27).**

Written to be executed phase by phase. Each phase compiles, passes `make test`, and is verifiable on its own. Read the root `AGENTS.md` (the successor-prefetch, "On track end", and playlist-editing guarantees), `Vibe/Playlist/AGENTS.md`, `Vibe/Playlist/Mac/AGENTS.md`, `Vibe/iOS/AGENTS.md`, `Vibe/Mac/Settings/AGENTS.md`, and `Tests/AGENTS.md` first; strings need the `vibe-strings` skill, verification the `vibe-debug` skill.

## The feature

With shuffle on, advancing plays every track in the playlist exactly once, in a random order, before the end is reached: a **shuffled permutation walked by a cursor**, as every mainstream player does it, not a per-advance random pick (which repeats some tracks and starves others).

- Turning it on shuffles the whole playlist into a hidden play order with the current track first. The visible order never changes, only what "next" means.
- **Next** walks forward through that order; **Previous** walks back through the tracks actually played (the permutation *is* the history).
- The end of the play order behaves like the end of the playlist today: park, don't restart. Reshuffle-and-continue is a repeat mode, which the app does not have and this plan does not add.
- Manually picking a row plays it and shuffle continues from it; the pick is spliced in at the cursor so nothing else repeats.
- Tracks appended while shuffling land at random positions in the *unplayed* remainder.
- Turning it off resumes linear order from the current track.
- The mode persists across launches; the order does not (a fresh launch reshuffles).

**Naming**: the feature is **shuffle**, in code and on screen. It is MediaPlayer's term (`changeShuffleModeCommand`) and every other player's, and "random" is not a synonym for it anywhere.

## Where linear order leaks today

`Playlist` (shared, host-less, tested in `Tests/PlaylistTests.m`) owns `currentIndex`, `hasNextTrack`/`hasPreviousTrack` (documented as the single source of truth for the boundaries), and `next`/`previous`, which move `currentIndex` through its setter and fire the one observer. Both shells funnel every advance through it. Five places compute the successor as `currentIndex + 1` instead of asking the model, and every one must ask the model's peek under shuffle:

- `Playlist.advanceFromTrack:toTrack:` — the gapless splice's bookkeeping half; it checks the started track against the next row.
- `Playlist.forwardTrackAfterRemovingTracksAtIndexes:` — what plays after the current row is removed; it walks forward in row order past the removed rows.
- `MainPlayerController.successorPrefetchTrack` — the mac's gapless arm point. The root guarantee makes the parked handle what a splice advances into, so a linear answer splices into the row neighbor while the UI expects the shuffled one.
- `PlaybackController.successorPrefetchTrack` — the same on iOS.
- The boundary check in `PlaybackController+PlayerEvents.m` (`didStartPlaying:`'s successor comparison) — compares the started track against the next row.

`grep -rn 'currentIndex + 1' Vibe` is the completeness check. The mac's `advanceOrParkAtTrackEnd` and the iOS `didFinishPlaying:` need no change: they read `hasNextTrack` and call `next`, which Phase 1 makes shuffle-aware. Menu validation gates Next and Previous on the same predicates. `changeShuffleModeCommand` is in `NowPlayingController`'s deliberately-disabled command set.

## Phase 1 — Shuffle in the `Playlist` model

The order lives **inside `Playlist`**: the boundary predicates are already the declared single source of truth, both shells funnel through them, and the model is the one shared, tested home. Foundation only, as now.

State: `@property BOOL shuffleEnabled;` and an injectable `uint32_t (^randomBelow)(uint32_t)` defaulting to `arc4random_uniform` (tests inject; never date- or seed-based in production). Internally, `_playOrder` (a permutation of row indexes) and `_playOrderCursor`. The guarantee every rule below applies: **entries before the cursor are played, the cursor entry is the current row, entries after it are unplayed.**

- **`setShuffleEnabled:YES`** — Fisher-Yates over all rows, swap the current row to position 0, cursor 0. **`NO`** — drop order and cursor; the linear predicates take over from `currentIndex` unchanged.
- **`hasNextTrack`** under shuffle is `cursor + 1 < count`; **`hasPreviousTrack`** is `cursor > 0`.
- **`next`/`previous`** under shuffle move the cursor, then set `currentIndex` through an internal write that skips the manual-pick splice below but still fires `currentIndexDidChangeFromIndex:`; observers must not care which mode moved it.
- **`nextTrackPeek`** — new public accessor: the track `next` would land on, shuffled or linear, or nil at the boundary. Every leak above asks it.
- **Manual pick** (`setCurrentIndex:` from outside `next`/`previous`) — swap the picked row's entry with the one at `cursor + 1` and advance to it. A played row is replayed and retires the slot it left, so nothing else repeats. Picking the current row changes nothing.
- **`replaceAllWithTracks:` / `clear`** — regenerate or drop the order; `replaceAll` still starts on row 0, which the new permutation puts first.
- **`appendTracks:`** — each new row lands at a `randomBelow`-chosen position in `(cursor, end]`.
- **`removeTracksAtIndexes:`, `insertTracks:atIndexes:`, `moveTracksAtIndexes:toIndexes:`** — `_playOrder` stores row indexes, so each remaps it: a removal drops its entries and shifts later indexes, an insert shifts them (inserted rows join the unplayed span at random positions), a move permutes them. The played/current/unplayed guarantee holds across each.
- **`replaceTrackAtIndex:withURL:`** (the convert swap) — no change: the swap moves no rows. Say so in the comment on `_playOrder`.

Tests (deterministic via `randomBelow`): every row visited exactly once walking to the boundary; the boundary parks; `previous` retraces the visited sequence; enabling puts the current row first; picking an unplayed row continues with no repeats; picking a played row replays it and still exhausts the remainder; appends land in the unplayed span; remove, insert, and move keep the guarantee; toggling off resumes linear; the convert swap changes nothing; `nextTrackPeek` always equals where `next` lands; `advanceFromTrack:toTrack:` accepts the shuffled successor and refuses the row neighbor; `forwardTrackAfterRemovingTracksAtIndexes:` answers the next unplayed track.

**Acceptance**: `make test`, `make check-layout`, `make build-ios`.

## Phase 2 — macOS

**Setting.** `AppSettings.h`, above the platform split: `shuffleEnabled`, key `Settings.shuffleEnabled`, default NO in the shared `registerDefaults`. The key string is permanent once shipped.

**Live effect.** Add `VibeSettingsLiveEffectShuffle` beside `VibeSettingsLiveEffectEndOfTrack` in `MainPlayerController+Settings`, applied by `applySettingsLiveEffects:` and at launch after the playlist restores. It pushes the setting into the model through a `PlaylistController` pass-through, then re-parks the successor with `prefetchTrack:self.successorPrefetchTrack`. **TRAP: without the re-park, a track end splices into the successor armed before the toggle.** Say in the `AppSettings.h` comment that a writer requests the effect, as the other live-effect settings do.

**Close the leak.** `successorPrefetchTrack` keeps its `pauseAtTrackEnd` gate (that guarantee outranks shuffle) and answers `nextTrackPeek` through a `PlaylistController` pass-through. Every other prefetch site already funnels through it.

**Menu.** A checkmarked Playback-menu item after Next in `MainMenuBuilder`, symbol `shuffle`, identifier `menu_shuffle`, no key equivalent (the bare transport keys belong to `TransportKeyMonitor`). Its action writes the setting and requests the live effect; `validateMenuItem:` keeps it enabled with the setting as its state. String `menu.playback.shuffle`, "Shuffle", then `make strings` and translations. No Settings-pane row: shuffle is transport state, not configuration.

**Acceptance**: `make test`, `make check-strings`, `make check-translations`; then through `vibe-debug`: toggle via `click_menu` and see it in `dump_state`; script a Next walk to the end and collect the sequence (a permutation, then park); toggle mid-track and confirm the next track end lands on a shuffled successor (the re-park); Previous retraces; a double-clicked row continues with no repeat; removing the playing row lands on the next unplayed track.

## Phase 3 — iOS

- `PlaybackController` applies the setting to its `Playlist` at init and gains `toggleShuffle`, writing the setting and the model together and ending on `applyTrackTransitionSettings` so the successor is re-parked. `successorPrefetchTrack` and the `didStartPlaying:` boundary check ask `nextTrackPeek`. `next`, `previous`, and `selectTrackAtIndex:` already go through the model.
- A shuffle button on the now-playing card's control row, tinted when active; `Vibe/iOS/Player/AGENTS.md` owns the card's layout conventions. The library rows and the mini player need nothing.
- **Open decision: the pager.** `PlayerViewController+Pager` pages by row index, so a swipe to the neighboring page is a manual pick of the adjacent row, which splices into shuffle with no repeat. Either accept that (the pager shows the playlist, and swiping picks) or page in play order. Decide before building the button.

**Acceptance**: `make build-ios`; on the simulator (`launch-ios.sh`, `drive-ios.sh`): toggle, advance through the folder, and confirm the no-repeat walk and the park at the end.

## Phase 4 (optional, separate decision) — Now Playing shuffle command

Enabling `changeShuffleModeCommand` puts a shuffle toggle in Control Center and CarPlay and routes it to the setting and its apply. **TRAP: `MPRemoteCommandCenter` is process-global, and the system may re-lay out the compact transport when a command appears** (the CarPlay doc's skip-command note). Verify on a device that it costs the lock screen nothing before shipping. The feature is complete without it.

## Final verification

- The scripted walk on a 50+ track folder: a permutation, no repeat or omission, park at the end.
- Toggle off mid-walk: the next advance is the next visible row.
- Append mid-walk: every appended track plays before the end, none twice.
- Convert a track mid-shuffle: the order is undisturbed, and the swapped row still plays once.
- `make test`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`, `make check-strings`, `make check-translations`, `make build-ios`.
- A `vibe-stress` torture run with shuffle on: shuffle changes which row a skip lands on, which is exactly the delivery-race surface its oracles watch.
