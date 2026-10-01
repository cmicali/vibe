# Future: Shuffle mode

**Status: planned, not implemented (verified 2026-10-01).** Issue #45, with `repeat-mode.md`.

Written to be executed phase by phase. Each phase compiles, passes `make test`, and is verifiable on its own. Read the root `AGENTS.md` (the successor-prefetch, "On track end", and playlist-editing guarantees), `Vibe/Playlist/AGENTS.md`, `Vibe/Playlist/Mac/AGENTS.md`, `Vibe/iOS/AGENTS.md`, `Vibe/iOS/Player/AGENTS.md`, `Vibe/Mac/Settings/AGENTS.md`, and `Tests/AGENTS.md` first; strings need the `vibe-strings` skill, verification the `vibe-debug` skill.

**Depends on `repeat-mode.md` Phase 1**, which moves the successor into the model (`nextTrack`, `trackEndSuccessor`) and closes the six places that compute it as the row neighbor. This plan only changes what those answers are under shuffle. Built first, shuffle takes that phase with it.

## The feature

With shuffle on, advancing plays every track in the playlist exactly once, in a random order: a **shuffled permutation walked by a cursor**, not a per-advance random pick (which repeats some tracks and starves others).

- **The playlist keeps its visible order** (decided on #45). Shuffle changes only what "next" means; nothing on screen reorders.
- Turning it on while a track plays shuffles the rest of the playlist behind it: the current track is first in the order.
- **Next** walks forward through the order; **Previous** walks back through the tracks actually played (the order *is* the history).
- The end of the order follows the repeat mode: Off parks, as the end of the playlist does today; All starts a fresh order (below); One replays the current track at its end and leaves Next to walk the order.
- Manually picking a row plays it and shuffle continues from it; the pick is spliced in at the cursor so nothing else repeats.
- Tracks appended while shuffling land at random positions in the *unplayed* remainder.
- Turning it off resumes linear order from the current track.
- The mode persists across launches; the order does not (a fresh launch reshuffles).

**Naming**: the feature is **shuffle**, in code and on screen. It is MediaPlayer's term (`changeShuffleModeCommand`) and every other player's, and "random" is not a synonym for it anywhere.

## Randomness

The proposal on #45: make a random order of every track; play it through; make a new one; repeat. That is the right algorithm, and the plan adopts it with one guard.

- **The order is a uniform Fisher-Yates shuffle**, from `arc4random_uniform`. Every order is equally likely, every track plays once per cycle, and no track waits longer than one cycle.
- **The seam guard.** A fresh cycle's order is independent of the last one, so with *n* tracks the track that just ended opens the next cycle one time in *n*, and on a ten-track album that is a back-to-back repeat every ten cycles. When the new order's first entry is the track that just ended and *n* > 1, swap it with a uniformly chosen later entry. One swap, and the only fix here worth its cost.
- **The first cycle** starts on the playing track when shuffle is turned on mid-play, and on a random track when a playlist is opened with shuffle already on (Phase 1, `replaceAllWithTracks:startingAtIndex:`).

Considered and not adopted:

| Option | What it fixes | Why not |
| --- | --- | --- |
| Random pick per advance, with replacement | Nothing; it is the naive version | Repeats tracks and starves others; on a ten-track album, about a third of the tracks go unheard in any ten picks. |
| A recency window instead of the one-track seam guard: none of the last *k* played open the next cycle | Near-repeats at the seam, not just back-to-back ones | Within a cycle every track already plays once, so the gap only shrinks at the seam; *k* = 1 removes the one case anyone notices. Widen it if a real playlist shows otherwise. |
| Artist or album spreading (Spotify's 2014 change, Fiedler's "balanced shuffle") | True randomness clusters same-artist tracks, which listeners read as "not random" | Needs each row's artist when the order is made, but metadata arrives later from the sweep, so the order would depend on scan timing. Most Vibe playlists are one folder, so it would usually do nothing. Revisit only if mixed-artist playlists become the norm. |
| Weighted by play count, rating, or recency across sessions | "Smart" shuffle favoring the neglected | Vibe has no library, no ratings, and no per-track history to weigh. |
| A persisted or seeded order | The same order after relaunch | No one has asked for it; the order is history, and history resets at launch. Tests get determinism from the injected `randomBelow`, not a seed. |

## Where linear order leaks today

`repeat-mode.md` lists the six places that compute the successor as the next row; after its Phase 1 they all ask `nextTrack` or `trackEndSuccessor`, so shuffle has one place to change. Two more places take the row order for "next" and need shuffle's attention:

- **The mac table's selection** and **the iOS library's row taps** are manual picks; they reach `setCurrentIndex:` and need nothing beyond the splice below.
- **Opening a playlist** sets `currentIndex` right after `replaceAllWithTracks:` (`PlaylistController.loadTracks:selectingIndex:` on the mac; `PlaybackController`'s `folderSession:didOpenTracks:…` on iOS). Under shuffle that set is a manual pick, which would mark the order's random first track as played without sounding it. Phase 1 gives the replace its start row instead.

`changeShuffleModeCommand` is in `NowPlayingController`'s deliberately-disabled command set.

## Phase 1 — Shuffle in the `Playlist` model

The order lives **inside `Playlist`**, beside the repeat mode: the successor answers are already the declared single source of truth, both shells funnel through them, and the model is the one shared, tested home. Foundation only, as now.

State: `@property BOOL shuffleEnabled;` and an injectable `uint32_t (^randomBelow)(uint32_t)` defaulting to `arc4random_uniform` (tests inject; never date- or seed-based in production). Internally, `_playOrder` (a permutation of row indexes), `_playOrderCursor`, and `_nextPlayOrder`, the next cycle's order once something has asked for it. The guarantee every rule below applies: **entries before the cursor are played, the cursor entry is the current row, entries after it are unplayed.**

- **`setShuffleEnabled:YES`** — Fisher-Yates over all rows, swap the current row to position 0, cursor 0. **`NO`** — drop the orders and the cursor; the linear answers take over from `currentIndex` unchanged.
- **`nextTrack`** under shuffle is the entry at `cursor + 1`. At the last entry it is nil under Off and One; under All it is the first entry of `_nextPlayOrder`, generated on first ask with the seam guard and kept, so the track the gapless splice armed is the track `next` lands on. **`hasPreviousTrack`** is `cursor > 0`.
- **`next`/`previous`** under shuffle move the cursor (stepping into `_nextPlayOrder` as the new order at the wrap), then set `currentIndex` through an internal write that skips the manual-pick splice below but still fires `currentIndexDidChangeFromIndex:`; observers must not care which mode moved it. Previous at cursor 0 of a later cycle parks; the previous cycle is not kept.
- **Manual pick** (`setCurrentIndex:` from outside `next`/`previous`) — swap the picked row's entry with the one at `cursor + 1` and advance to it. A played row is replayed and retires the slot it left, so nothing else repeats. Picking the current row changes nothing. Any `_nextPlayOrder` is dropped, since the cycle it continued has changed.
- **`replaceAllWithTracks:startingAtIndex:`** replaces `replaceAllWithTracks:`. The start row is the current index after the replace; `NSNotFound` means "the model's choice", which is row 0 linear and the order's random first under shuffle. The mac passes `selectingIndex` (with `NSNotFound` for a plain open, which passes 0 today), the launch restore passes its saved row, and iOS resolves `selectedURL` to a row before the replace rather than after. **TRAP: a `currentIndex` set after the replace is a manual pick under shuffle.** **`clear`** drops the orders.
- **`appendTracks:`** — each new row lands at a `randomBelow`-chosen position in `(cursor, end]`; a pending `_nextPlayOrder` is dropped and regenerated on the next ask.
- **`removeTracksAtIndexes:`, `insertTracks:atIndexes:`, `moveTracksAtIndexes:toIndexes:`** — `_playOrder` stores row indexes, so each remaps it: a removal drops its entries and shifts later indexes, an insert shifts them (inserted rows join the unplayed span at random positions), a move permutes them. Each drops `_nextPlayOrder`. The played/current/unplayed guarantee holds across each.
- **`replaceTrackAtIndex:withURL:`** (the convert swap) — no change: the swap moves no rows. Say so in the comment on `_playOrder`.
- **Repeat One** needs nothing of shuffle: `trackEndSuccessor` is the current track in either order.

Tests (deterministic via `randomBelow`): every row visited exactly once walking to the boundary; the boundary parks under Off; under All the walk continues into a second full cycle whose first track is not the last one played; `nextTrack` at the last entry under All equals where `next` lands, asked once or twice; `previous` retraces the visited sequence and parks at a cycle's start; enabling puts the current row first; opening with `NSNotFound` under shuffle starts on the injected order's first row and marks nothing played; picking an unplayed row continues with no repeats; picking a played row replays it and still exhausts the remainder; appends land in the unplayed span; remove, insert, and move keep the guarantee; toggling off resumes linear; the convert swap changes nothing; `advanceFromTrack:toTrack:` accepts the shuffled successor and refuses the row neighbor; `forwardTrackAfterRemovingTracksAtIndexes:` answers the next unplayed track.

**Acceptance**: `make test`, `make check-layout`, `make build-ios`.

## Phase 2 — macOS

**Setting.** `AppSettings.h`, above the platform split, beside `pauseAtTrackEnd` and `repeatMode`: `shuffleEnabled`, key `Transport.shuffleEnabled`, default NO in the shared `registerDefaults`. The key string is permanent once shipped.

**Live effect.** None of its own: `VibeSettingsLiveEffectEndOfTrack`'s apply already pushes the transport modes into the model and re-parks the successor (`repeat-mode.md` Phase 2); it gains `shuffleEnabled`. **TRAP: without the re-park, a track end splices into the successor armed before the toggle.**

**Menu.** A checkmarked Playback-menu item after Next, with the Repeat item after it, symbol `shuffle`, identifier `menu_shuffle`, **⌥⌘S** (⌘S is Save Playlist). Its action writes the setting and requests the effect; `validateMenuItem:` keeps it enabled with the setting as its state. String `menu.playback.shuffle`, "Shuffle", then `make strings` and translations. No Settings-pane row: shuffle is transport state, not configuration. The menu and the shortcut are the mac's whole surface (decided on #45).

**Debug.** `set_shuffle <on|off>` beside `set_repeat`, and `shuffleEnabled` plus the play order in both `dump_state`s, so a scripted walk can be checked against it.

**Acceptance**: `make test`, `make check-strings`, `make check-translations`; then through `vibe-debug`: toggle via `click_menu` and ⌥⌘S and see it in `dump_state`; script a Next walk to the end and collect the sequence (a permutation, then park); repeat it under All and see a second permutation follow without a back-to-back repeat; toggle mid-track and confirm the next track end lands on a shuffled successor (the re-park); Previous retraces; a double-clicked row continues with no repeat; removing the playing row lands on the next unplayed track; opening a folder with shuffle on starts on a random row.

## Phase 3 — iOS

- `PlaybackController` pushes the setting into its `Playlist` at init and in `applyTrackTransitionSettings`, and gains `toggleShuffle`, writing the setting and ending on `applyTrackTransitionSettings` so the successor is re-parked. `next`, `previous`, and `selectTrackAtIndex:` already go through the model.
- A shuffle button at the leading end of the transport row, `shuffle` dimmed off and tinted on; repeat takes the trailing end, and `repeat-mode.md` Phase 3 has the layout and its landscape check. The library rows and the mini player need nothing.
- **The pager pages in playlist order** (follows from keeping the visible order). A swipe to a neighboring page is a manual pick of that row, which splices into the order with no repeat. Next and the end of a track usually land on a page far from the current one: the commit must jump there without animating through every page between, and the art prefetch around the current page (`kArtPrefetchRadius`) must still center on the landing page.

**Acceptance**: `make build-ios`; on the simulator (`launch-ios.sh`, `drive-ios.sh`): toggle, advance through the folder, and confirm the no-repeat walk, the park at the end under Off, the jump to a distant page without a long scroll, and a swipe continuing with no repeat.

## Phase 4 — Now Playing shuffle command

In scope (decided on #45), the same shape as repeat's (`repeat-mode.md` Phase 4), and built with it when both modes exist: take `changeShuffleModeCommand` out of `NowPlayingController`'s disabled set, route `MPChangeShuffleModeCommandEvent` through a `nowPlayingController:setShuffleEnabled:` delegate method to the setting and its apply, and set `currentShuffleType` wherever the mode is applied. `MPShuffleTypeItems` and `MPShuffleTypeCollections` both mean on: Vibe has no album-level shuffle, and reporting back `Items` tells the system which it got. The device checks are repeat's: what each surface draws, and the lock screen keeping Next and Previous.

## Final verification

- The scripted walk on a 50+ track folder: a permutation, no repeat or omission, park at the end under Off; under All, a second permutation with no back-to-back repeat at the seam.
- Toggle off mid-walk: the next advance is the next visible row.
- Append mid-walk: every appended track plays before the end, none twice.
- Convert a track mid-shuffle: the order is undisturbed, and the swapped row still plays once.
- `make test`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`, `make check-strings`, `make check-translations`, `make build-ios`.
- A `vibe-stress` torture run with shuffle on, and one with shuffle and repeat All: shuffle changes which row a skip lands on, which is exactly the delivery-race surface its oracles watch.

## Budget

New types: none (the enum is repeat's). New files: none. Removes: `replaceAllWithTracks:` and the set-after-replace in both shells' open paths, replaced by one call that carries the start row. No live effect of its own: shuffle rides `EndOfTrack`.
