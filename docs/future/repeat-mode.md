# Future: Repeat mode

**Status: planned, not implemented (verified 2026-10-01).** Issue #45, with `shuffle-mode.md`.

Written to be executed phase by phase. Each phase compiles, passes `make test`, and is verifiable on its own. Read the root `AGENTS.md` (the "On track end", successor-prefetch, play-settlement, and playlist-editing guarantees), `Vibe/Playlist/AGENTS.md`, `Vibe/iOS/AGENTS.md`, `Vibe/iOS/Player/AGENTS.md`, and `Tests/AGENTS.md` first; strings need the `vibe-strings` skill, verification the `vibe-debug` skill.

**Build this before shuffle.** Phase 1 here moves the successor decision into the model and closes every place a shell computes it as the row neighbor. Shuffle then only changes what the model answers. Shuffle built first must take this phase's seam with it.

## The feature

Three modes, as every player has them: **Off**, **All**, **One**.

- **Off** — today's behavior: the end of the playlist parks.
- **All** — after the last track, playback continues from the first. Under shuffle, it continues into a fresh shuffled order (`shuffle-mode.md`, "Randomness").
- **One** — a track that plays out replays from its start, indefinitely. **One changes only the natural track end**: Next and Previous behave exactly as under Off, so the user can still walk the playlist, and the new track then repeats.
- **Previous never wraps**, in any mode: at the first track it parks as now. Wrapping backwards is rarely wanted and, under shuffle, would need the previous cycle's order, which is not kept.
- **"On track end: Pause" outranks every repeat mode.** Pause parks on the finished track whatever repeat says; repeat decides only *where* an advance goes, Pause whether one happens. They stay separate controls: Pause is configuration in Settings, repeat is transport state the user flips while listening.
- The mode persists across launches, like shuffle.

**Naming**: **repeat**, with the modes **Off**, **All**, and **One** — MediaPlayer's `MPRepeatType` names, and Music.app's. "Loop" is not a synonym anywhere.

## Where the successor is computed today

`Playlist.hasNextTrack` is documented as the single source of truth for the boundary, but six places compute the successor itself as the next row:

- `Playlist.advanceFromTrack:toTrack:` (`Playlist.m`) — the gapless splice's bookkeeping checks the started track against row `currentIndex + 1`.
- `Playlist.forwardTrackAfterRemovingTracksAtIndexes:` — walks forward in row order past the removed rows.
- `MainPlayerController.successorPrefetchTrack` — the mac's gapless arm point.
- `PlaybackController.successorPrefetchTrack` — the same on iOS.
- `PlaybackController+PlayerEvents.m`, `didAutoAdvanceFromTrack:toTrack:` — compares the started track against the next row before adopting a splice.
- `PlayerViewController+Pager.m`, the page configuration — dims a page's Next from `index + 1 < _playlist.count`.

The track-end readers — the mac's `advanceOrParkAtTrackEnd` and the iOS `didFinishPlaying:` — read `hasNextTrack` and then call `next`, which suits Off and All but not One, which must replay rather than advance. `grep -rn 'currentIndex + 1\|index + 1 <' Vibe` is the completeness check after Phase 1; it should find only `Playlist.m`'s own linear branch.

## Phase 1 — The successor lives in `Playlist`

Shared, Foundation only, tested in `Tests/PlaylistTests.m`.

**Type.** `typedef NS_ENUM(NSInteger, VibeRepeatMode) { VibeRepeatModeOff, VibeRepeatModeAll, VibeRepeatModeOne };` in `Playlist.h`. This is the feature's one new type: three states that a pair of BOOLs would encode with a fourth, meaningless one.

**State.** `@property (nonatomic) VibeRepeatMode repeatMode;` on `Playlist`. The model never reads `AppSettings`; each shell pushes the setting in.

**Two answers, because One makes a manual skip and a track end differ:**

- **`nextTrack`** — where Next lands, or nil at the boundary. Off and One: the next row. All: the next row, wrapping to row 0 at the end. `hasNextTrack` becomes `nextTrack != nil`; `next` moves the cursor to it.
- **`trackEndSuccessor`** — what a track that plays out is followed by, or nil to park. One: the current track itself. Otherwise `nextTrack`.
- **`advanceAtTrackEnd`** — moves the cursor to `trackEndSuccessor` and returns NO when it is nil. Under One it re-sets the same index, which already fires `currentIndexDidChangeFromIndex:` for an unchanged index (the double-click-replay case), so observers re-render as for any play.
- **`advanceFromTrack:toTrack:`** accepts `startedTrack == trackEndSuccessor`, including `startedTrack == finishedTrack` under One, then advances with `advanceAtTrackEnd`.
- **`forwardTrackAfterRemovingTracksAtIndexes:`** answers the first survivor `nextTrack` would reach, wrapping under All. One does not apply: a removal is not a track end.
- `hasPreviousTrack` and `previous` are unchanged in every mode.

**Shells ask the model.** Both `successorPrefetchTrack`s become `VibePlaybackShouldAdvanceAtTrackEnd(trackEndSuccessor != nil, pauseAtTrackEnd) ? trackEndSuccessor : nil`. The mac's `advanceOrParkAtTrackEnd` and the iOS `didFinishPlaying:` read the same predicate, then call `advanceAtTrackEnd` and play the current track, in place of `next`. iOS's `didAutoAdvanceFromTrack:toTrack:` asks `advanceFromTrack:toTrack:`, as the mac's already does, instead of comparing rows itself. The iOS card's Next asks the model's `hasNextTrack` on the current page; any other page keeps today's last-row rule under Off and One and stays lit under All. `VibePlaybackShouldAdvanceAtTrackEnd`'s first parameter is renamed `hasTrackEndSuccessor`; it stays the one rule both reads use.

**Repeat One through the gapless splice.** Under One the parked successor is the current track's own `AudioTrack`, so the player opens a second handle on the playing file and splices into its start, which makes One gapless. The prefetch disposition compares against the parked key and the *pending* play's key, so no settled playback suppresses it. The handle ceiling's two-source derivation holds: it is still one playback and one prefetch slot. `didAutoAdvanceFromTrack:X toTrack:X` then reaches each shell. Verify in Phase 2 what a same-object start does to each `performPerTrackRefreshForStartedTrack:`-style refresh: the playhead, the waveform's played side, and Now Playing's elapsed time must return to 0, and the stats must count a second play.

**Tests.** Per mode: `nextTrack`, `trackEndSuccessor`, `hasNextTrack`, and `hasPreviousTrack` at the first, a middle, and the last row, and in a one-row and an empty playlist; `advanceAtTrackEnd` walks to the boundary and parks under Off, wraps under All, and stays put under One while still notifying; Next under One advances and parks at the end; Previous never wraps; `advanceFromTrack:toTrack:` accepts the wrap under All and the same object under One, and refuses the row neighbor under One; `forwardTrackAfterRemovingTracksAtIndexes:` wraps under All when the last rows are removed. `PlaybackDeliveryRulesTests` keeps Pause outranking a non-nil successor.

**Acceptance**: `make test`, `make test-audio`, `make check-layout`, `make check-vocabulary`, `make build-ios`. With the mode at Off, behavior is unchanged on both shells.

## Phase 2 — macOS

**Setting.** `AppSettings.h`, above the platform split, beside `pauseAtTrackEnd`: `repeatMode`, key `Transport.repeatMode` (an integer), default Off in the shared `registerDefaults`. The key is permanent once shipped. Its comment says what `pauseAtTrackEnd`'s says: the store never applies it, and a writer that skips the re-park leaves an armed splice into the old successor.

**Live effect.** No new bit. `VibeSettingsLiveEffectEndOfTrack`'s `applyEndOfTrackAction` first pushes `repeatMode` (and, once it exists, `shuffleEnabled`) into the model through `PlaylistController`, then re-parks with `successorPrefetchTrack` as it does now. Launch applies it after the playlist restores. **TRAP: without the re-park, a mid-track switch from Off to One lets the armed splice advance anyway.**

**Menu.** One Playback-menu item after Shuffle, its title naming the mode — "Repeat: Off", "Repeat: All", "Repeat: One" — checked unless Off, symbol `repeat` (`repeat.1` under One), identifier `menu_repeat`, **⌘R**. Choosing it cycles Off → All → One → Off, the order iOS's button uses, writes the setting, and requests the effect; `validateMenuItem:` sets the title and state. Three whole strings, `menu.playback.repeat.off`, `.all`, and `.one`, never a "Repeat: %@" built from a mode name, since word order differs by language. ⌘R is a character default in `Mac/Menu/ShortcutRules.h`'s table (`VibeShortcutMakeCharacter('r', ⌘)`), so it is remappable in Settings > Keyboard Shortcuts and the builder passes `@"", 0`; as a character default the menu bar matches it, and the effect keys' release is matched by the key code that went down, so the delay's R is unaffected. `VibeTransportMenuEnabled` already gates Next on `hasNextTrack`, so Next lights at the last row under All with no change. `make strings`, then translations.

**No header indicator.** The header's FX symbols already draw `repeat` and `repeat.circle` for the delays (`TrackDisplayController`'s `fxSymbolNames`); a repeat glyph there would read as an FX. The menu and ⌘R are the mac's whole surface, as for shuffle (decided on #45).

**Debug.** `set_repeat <off|all|one>` beside `set_pause_at_track_end`, applied through the same `debugApplyEndOfTrackSetting`, and `repeatMode` in both `dump_state`s.

**Acceptance**: `make test`, `make check-strings`, `make check-translations`, `make analyze CONFIG=Release`; then through `vibe-debug` on a short folder: under All, play the last track to its end and see row 0 start, gaplessly when gapless is allowed; under One, let a track end twice and see it replay each time with the playhead at 0; ⌘R cycles the mode and the menu title follows; flip Off to One mid-track and see the end replay (the re-park); Next under One walks forward; Pause set alongside One parks.

## Phase 3 — iOS

- `PlaybackController` pushes the mode into its `Playlist` at init and in `applyTrackTransitionSettings`, which every writer already ends on and which already re-parks. A `cycleRepeatMode` (Off → All → One → Off, the iOS convention) writes the setting and applies.
- **The pair flanks the transport row** (decided on #45): shuffle, previous, play, next, repeat, in both card layouts, as the row's own buttons (`makeTransportButton`). Repeat draws `repeat` dimmed at Off, tinted at All, and `repeat.1` tinted at One. The tint and the dim are drawn images, under the same TRAP as Next's disabled look (`setGlyph:onButton:pointSize:`): an alpha over a system button's own dimming compounds. Portrait has the width. **Landscape is the risk**: the row sits between the FX pad and the route pill, and the pill already gives way to the row, so a two-button-wider row squeezes the device name; check the smallest supported phone in landscape with a long AirPlay name, and shrink the flanking buttons' glyphs before the row's spacing. Record the layout in `Vibe/iOS/Player/AGENTS.md`.
- No row in Settings > Playback: like shuffle, it is transport state.

**Acceptance**: `make build-ios`; on the simulator (`launch-ios.sh`, `drive-ios.sh`): cycle the button and see the glyph; check both layouts on the smallest phone, landscape with a long route name; seek near the end of the last track under All and see the first page commit; seek near the end under One and see the same page replay; Next on the last page lights under All.

## Phase 4 — Now Playing

In scope (decided on #45). There is no shuffle or repeat field in the Now Playing info: each mode is a remote command with a handler and a state property, both in the shared `NowPlayingController`, so both platforms get it at once.

- **The handler.** Take `changeRepeatModeCommand` out of the disabled set and register it like the transport commands, through `deliverRemoteCommand:to:`. A new `NowPlayingControllerDelegate` method, `nowPlayingController:setRepeatMode:`, maps `MPChangeRepeatModeCommandEvent.repeatType` straight across (`MPRepeatType` has the same three cases); each shell writes the setting and applies exactly as its menu or button does.
- **The state.** `changeRepeatModeCommand.currentRepeatType` is set wherever the mode is applied — the mac's `EndOfTrack` apply, iOS's `applyTrackTransitionSettings` — so a change from the menu, ⌘R, the iOS button, or the system itself always reaches it.
- **Where it shows is the system's choice.** Expect Siri ("repeat this song"), the Watch's Now Playing, and accessories; the lock screen and Control Center are not known to draw repeat for third-party apps; CarPlay's Now Playing needs its repeat button added explicitly once `carplay.md` is built. Record what each surface does on a device.
- **Verify the lock screen keeps Next and Previous** after enabling the command, on a device. The known trade (`carplay.md`) is the skip-interval commands competing for those slots; repeat is not expected to, but `MPRemoteCommandCenter` is process-global and the check is cheap.

Shuffle's command follows the same shape (`shuffle-mode.md` Phase 4); build them together if both modes exist by then.

**Acceptance**: on a device, Siri sets each mode and the menu or card follows; changing the mode in the app updates `currentRepeatType`; the lock screen's compact transport is unchanged.

## Docs to update when this lands

- Root `AGENTS.md`, "On track end": the successor both reads use is the model's `trackEndSuccessor`, and Pause outranks the repeat mode.
- `Vibe/Playlist/AGENTS.md`: the two answers, `nextTrack` and `trackEndSuccessor`, and why One splits them.
- `docs/future/repeat-mode.md`: delete it, as each landed future doc is.

## Budget

New types: `VibeRepeatMode`. New files: none. Removes: the six row-neighbor successor computations, which collapse into the model's two answers, and the shuffle plan's separate live effect, which this folds into `EndOfTrack`.
