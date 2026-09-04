# Reopen last playlist (macOS) — DONE

Implemented 2026-09-04, from the plan below, on top of File > Save Playlist… (PR #21). The plan is
kept as the record of the reasoning; the code and the directory docs are the authority on what
shipped. The implementation diverged in two places:

- **The sudden-termination hold follows the setting alone, not the setting and a nonempty
  playlist.** Verified live: with the hold released after Close, the quit that followed ran no
  `applicationWillTerminate:` at all (the repo's `AppStats` comment had said as much), so the
  empty-at-quit deletion never happened and the stale mirror was restored at the next launch.
  Holding for as long as the setting is on keeps every quit on the callback path.
- The mirror's reader builds its URLs with `fileURLWithPath:isDirectory:NO`, because the plain
  constructor stats the path to decide, and "nothing is stat'd at launch" is the plan's own promise.
- The Startup section sits below Audio rather than first, and the copy shipped as "Load last
  playlist on launch" with the caption "Playlist is saved on quit and loaded on next launch"; the
  keys are unchanged.

**This replaced the design of 2026-08-25 that lived in this file** (git history keeps it, last at
`7d38d64`). Two things changed since it was written: the row-removal feature added a paused-open
park (`playStartPaused:`), which made its Part 1 — a sixth display state — unnecessary, and the
M3U writer made its Part 2 — a bespoke plist store with per-file bookmarks and a debounced writer
— unnecessary. Its costing of a 50k-row restore and its dataless-waveform trap were read and are
folded into the decisions below.

## The feature

**At quit, the playlist is saved as an M3U inside the app container; at the next launch it is
reopened with the last current track parked, unless a launch-time open outranks it.** A switch in
Settings > General, new Startup section, "Reopen last playlist", off by default; turning it off
deletes the saved file. Issue #19's "bonus points for auto-load".

Decisions taken during planning:

| | |
| --- | --- |
| Restore landing | **Paused open** of the last current track through the removal funnel's park (`PlaylistController.playStartPaused:YES`, `Vibe/Playlist/Mac/PlaylistController.m:682-702`). Renders as any paused track at 0:00; the engine stays off (`AudioPlayer.m:755-763`). Accepted costs: a cloud-only current track downloads at launch through the coordinator, and one flag keeps Now Playing unpublished until the first real play. |
| Save timing | **At quit only**, in `applicationWillTerminate:`. `NSSupportsSuddenTermination: YES` (`project.yml:264`) makes a quit from paused or stopped a SIGKILL with no callback, so the app holds sudden termination off while the setting is on and the playlist is nonempty. A crash or force quit loses the session (accepted). |
| Default | **Off.** Launch stays byte-for-byte what it is today unless the user turns it on. |
| Unreadable rows | **Every row is kept**: no stats, no permission prompt at launch. A row the sandbox cannot read lands in the existing inline error state when opened, and comes back once its volume mounts. |
| Storage | `Application Support/<bundle id>/LastPlaylist.m3u`, absolute paths, plus the current track's path in one `NSUserDefaults` state key. An empty playlist at quit, or the setting off, deletes the file. |
| Platform | macOS only. iOS already restores its folder session. |

## What exists (anchors verified at `fdc473e`)

- **Launch**: `AppDelegate.applicationDidFinishLaunching:` (`Vibe/Mac/App/AppDelegate.m:145-152`) runs `restoreGrantedAccessWithCompletion:` (completion on main, deadlined) and inside it `startAndDrainQueue` → else `revealEmptyState`. An empty drain leaves `_burstActive` NO and arms no timer (`OpenBurstCoalescer.m:44-51`), so a Finder open a beat later still *replaces*. `applicationWillTerminate:` (`:309-312`) is one `AppStats playbackStopped` line; `AppStats` is the only other user of the sudden-termination counter (`Vibe/Common/AppStats.m:99,117`, self-balancing).
- **The park**: `playStartPaused:YES` opens the file (a dataless one downloads through the coordinator), never starts the engine, fires `didStartPlaying:` so the per-track refresh (waveform, art, duration cache, Open Recent note, prefetch) comes free, and `performPerTrackRefreshForStartedTrack:` (`+PlayerEvents.m:106-155`) skips `AppStats playbackStarted` and pauses the UI timer for a not-playing start. The removal funnel's prelude (`MainPlayerController.m:867-879`: error mask, download monitor, stats fold, timer) tears down a *previous* track and is dead at launch; the restore's prelude is `play:`'s (`:607-622`).
- **Now Playing**: `updateNowPlaying` (`+NowPlaying.m:21-76`) publishes the displayed track's *identity* even in the Loading gap (zero position, metadata duration, rate 0), and `NowPlayingController.updateWithTrack:` (`Vibe/System/NowPlayingController.m:253-282`) applies next/previous command availability before its nil-track early return, which publishes nothing while `_hasPublished` is NO. So a paused restore would claim the slot at launch through `playWillStartHandler`'s `updateUI` **before** any flag set afterwards — the flag must be set before the submission.
- **`updateUI`** is reached after every count transition: `reconcileAfterPlaylistStructureEdit` (`:897`, the tail of append, non-current removal, reinsert, reorder), `playWillStartHandler` (`:223`, every funnel play including a removed current row's park), `closeFile:` (`:707`), `windowDidLoad` (`:120`). It already reads a setting per pass (`syncUITimerRate` → `uiUpdateHzCap`, `:411`).
- **Live effects**: `VibeSettingsLiveEffectAll = NSUIntegerMax` (`+Settings.h:61`), and `SettingsAdvancedViewController.resetSettings:` (`.m:163-165`) applies `All` after `resetToDefaults`, so a new bit reaches the reset for free.
- **Container path precedent**: `AppTheme.m:496-516` builds `Application Support/<bundle id>/ThemeArt` from `NSSearchPathForDirectoriesInDomains` (static to that file, with a test seam). `make reset-state` wipes the whole container (`scripts/reset-state.sh:56-65`).
- **Settings UI**: `SettingsGeneralViewController.m` sections at `:81-92`; the Always-on-top switch shape at `:66` / `:86` / `:99` / `:105-108`; `SettingsRowView.rowWithTitle:caption:control:` (`SettingsFormViews.h:31-33`) exists with no caller yet.
- **`PlaylistController.play:`** (`.m:665-671`) = `replaceAllWithURLs:` + scroll + `[self play]`; its only caller is `MainPlayerController.play:` (`:615`). `Playlist.setCurrentIndex:` does not range-check.
- **Debug**: `set_pause_at_track_end` (`DebugCommandTable.m:333-344`) is the settings-verb shape; `DebugStateDump.m:92-134` is the `settings` block; `MainPlayerController.m:1137-1163` is the controller's `#if DEBUG` block; `quit` runs `applicationWillTerminate:`.

## Step 1 — `PlaylistFile.fileURLsInM3UData:` (shared, Foundation-only, tested)

The reader for a file this app wrote itself. `resolvedFileURLsForPlaylistAtURL:` cannot serve: its `ResolveEntry` stats candidates per entry. The composition is six lines, but `MainPlayerController.m` is not in `VibeTests` while `PlaylistFile.m` is, and the writer's header already promises the round trip.

`Vibe/Playlist/PlaylistFile.h`, after `resolvedFileURLsForPlaylistAtURL:`:

```objc
// The entries of M3U data this app wrote itself — m3uTextForTracks: with a
// nil directory, so every entry is absolute — as file URLs in order, with no
// resolution rungs and no probes: nothing is stat'd, a relative entry is
// skipped. The reader for the container mirror; a user's playlist file goes
// through resolvedFileURLsForPlaylistAtURL:.
+ (NSArray<NSURL *> *)fileURLsInM3UData:(NSData *)data;
```

`.m`: `textFromData:` → `m3uEntriesInText:` → `fileURLWithPath:` for each `/`-prefixed entry whose URL has a path. Empty data → `@[]`.

## Step 2 — `PlaylistController.loadURLs:selectingIndex:` replaces `play:`

`Vibe/Playlist/Mac/PlaylistController.h/.m`: `loadURLs:selectingIndex:` = `replaceAllWithURLs:`, then `self.currentIndex = index` only when `index > 0 && index < count` (the replacement already announced 0; the setter's observer repaints both rows and re-ranks the neighborhood), then `scrollCurrentTrackToVisible`. **Delete `play:`** — the shell becomes its only former caller's replacement (Step 3). `playStartPaused:` stays the one play funnel. Update `Playlist/Mac/CLAUDE.md` ("`play:` replaces" → `loadURLs:selectingIndex:`) and `Playlist/CLAUDE.md`'s last line.

## Step 3 — `MainPlayerController`: one replacement path, the mirror, the restore, the hold, the flag

All in `Vibe/Mac/MainWindow/MainPlayerController.m` (the playlist entry points live there), new `#pragma mark - The last playlist` after `writePlaylistToURL:error:`.

**The one replacement path.** `play:` becomes `[self loadURLs:urls selectingIndex:0 startPaused:NO]`, and:

```objc
// An open and the launch restore differ only in the row they land on and
// whether it sounds.
- (void)loadURLs:(NSArray<NSURL *> *)urls selectingIndex:(NSUInteger)index startPaused:(BOOL)startPaused {
    _emptyStateSuppressed = NO;                      // a real track supersedes the launch grace
    [self.metadataCache cancelScan];                 // play:'s existing comment moves here
    [self.playlistController loadURLs:urls selectingIndex:index];
    [self.playlistController playStartPaused:startPaused];
    [self scheduleDeferredMetadataLoad];             // play:'s existing comment moves here
}
```

**Path and key**, private to the file: `static NSString *const kVibeLastPlaylistCurrentPathKey = @"VibeLastPlaylistCurrentPath";` (state, not a preference — the `VibeGrantedFolders` / `VibeiOSLastTrackFileName` precedent; `resetToDefaults` must not be what clears it) and `static NSURL *VibeLastPlaylistURL(void)` building `Application Support/<bundle id>/LastPlaylist.m3u` the way `AppTheme.m:496-516` does (three duplicated lines; that function is static to `AppTheme` and carries a test seam).

**Quit-time save** (`saveLastPlaylist`, public): if the setting is off or the playlist is empty → `removeLastPlaylist` (delete the file, remove the key). Else create the directory, `[PlaylistFile m3uTextForTracks:tracks relativeToDirectory:nil]`, lossy UTF-8, `NSDataWritingAtomic`; on failure `LogError` and remove (a stale mirror must not outlive a failed write); on success store `currentTrack.url.path.stringByStandardizingPath` under the key. Synchronous on main; ~100 ms at 50k rows.

**Restore** (`restoreLastPlaylist`, public, returns BOOL):

```objc
- (BOOL)restoreLastPlaylist {
    if (!AppSettings.sharedInstance.reopenLastPlaylist) { return NO; }
    NSData *data = [NSData dataWithContentsOfURL:VibeLastPlaylistURL()];
    NSArray<NSURL *> *urls = data ? [PlaylistFile fileURLsInM3UData:data] : @[];
    if (urls.count == 0) { return NO; }
    // Every row comes back, readable or not; an unreadable current row lands
    // in the inline error state when its parked open fails.
    NSString *currentPath = [NSUserDefaults.standardUserDefaults stringForKey:kVibeLastPlaylistCurrentPathKey];
    NSUInteger index = [urls indexOfObjectPassingTest:^BOOL(NSURL *url, NSUInteger i, BOOL *stop) {
        return [url.path isEqualToString:currentPath];
    }];
    // BEFORE the submission: the loading gap publishes the track's identity
    // through playWillStartHandler's updateUI, and nothing may be published
    // until a track plays.
    _nowPlayingWithheldForRestore = YES;
    [self loadURLs:urls selectingIndex:(index == NSNotFound ? 0 : index) startPaused:YES];
    return YES;
}
```

**The Now Playing flag.** Ivar `BOOL _nowPlayingWithheldForRestore` in `MainPlayerControllerInternal.h`'s class extension (two categories touch it). `updateNowPlaying` (`+NowPlaying.m:30`) resolves `track` to nil while the flag is set — the call still runs so next/previous availability tracks the playlist. Cleared in two places in `+PlayerEvents.m`: at the top of `didStartPlaying:` **when `self.audioPlayer.isPlaying`** (a real start; a paused start leaves it), and at the top of `didResumePlaying:` (the parked track resumed by Space, `playPause:`, or the remote Play command). Every other way out of the park goes through one of those two; a seek on the paused node re-publishes Paused and stays withheld. Not `playWillStartHandler`: it fires for the restore's own parked submission.

**The sudden-termination hold.** Ivar `BOOL _holdsSuddenTerminationForPlaylist` private to the `.m`.

```objc
// Quit from Paused or Stopped is a SIGKILL under NSSupportsSuddenTermination,
// with no applicationWillTerminate: to write the mirror — so while there is a
// playlist to mirror, the hold keeps the quit on the callback path. The
// counter is process-wide and shared with AppStats' listening-clock hold;
// each side balances its own pair, this one by construction. Runs from the
// updateUI funnel, which every structural edit and transport event reaches.
- (void)syncSuddenTerminationHold {
    BOOL wanted = AppSettings.sharedInstance.reopenLastPlaylist && self.playlistController.count > 0;
    if (wanted == _holdsSuddenTerminationForPlaylist) { return; }
    if (wanted) { [NSProcessInfo.processInfo disableSuddenTermination]; }
    else        { [NSProcessInfo.processInfo enableSuddenTermination]; }
    _holdsSuddenTerminationForPlaylist = wanted;
}
```

Called from `updateUI` after `syncUITimerRate`, and from the live effect.

**The live effect** (`applyReopenLastPlaylist`, declared in `MainPlayerControllerInternal.h` under "Settings live effects"): off → `removeLastPlaylist` (off means forget, not merely stop writing); either way `syncSuddenTerminationHold`. Nothing is written until quit.

**Public header** (`MainPlayerController.h`, beside `revealEmptyState`): `restoreLastPlaylist` and `saveLastPlaylist`, each with a two-line comment (not an open: no stats, no bookmarks, no Open Recent, no burst; the hold is what guarantees the quit reaches the save).

## Step 4 — launch and quit wiring (`Vibe/Mac/App/AppDelegate.m`)

```objc
    [[FolderAccessManager sharedInstance] restoreGrantedAccessWithCompletion:^{
        // A launch-time open outranks the remembered playlist. The restore is
        // not an open: it enters neither the coalescer — an empty drain leaves
        // no burst, so a Finder open a beat later replaces — nor
        // openURLs:appending:, so no stats, no bookmarks, no Open Recent.
        if (![self->_openBurstCoalescer startAndDrainQueue]
                && ![self.mainPlayerController restoreLastPlaylist]) {
            [self.mainPlayerController revealEmptyState];   // existing comment stays
        }
    }];
```

`applicationWillTerminate:` gains `[self.mainPlayerController saveLastPlaylist];` after the `AppStats` line.

## Step 5 — the setting and its effect bit

- `Vibe/Common/Mac/AppSettings+Mac.m`: `#define SETTING_REOPEN_LAST_PLAYLIST @"Playlist.reopenLast"` beside `SETTING_PAUSE_AT_TRACK_END` (`:31`); `@(NO)` in `registerMacDefaultsInto:` (`:80-104`, which also feeds `allSettingsAtDefaults` and `resetToDefaults`); `boolForKey:`/`setBool:` accessors beside `pauseAtTrackEnd` (`:593-599`). `AppSettings+Mac.h` beside `:227-234`: `reopenLastPlaylist` with a doc block naming the mirror's owner and the effect a writer must request.
- `+Settings.h` after `WaveformLevels` (`:48`): `VibeSettingsLiveEffectReopenLastPlaylist = 1UL << 20`; `+Settings.m` after the `EndOfTrack` branch: `if (effects & …) { [self applyReopenLastPlaylist]; }`. `All` already covers it, so Factory Reset needs no explicit call.

## Step 6 — Settings UI (`Vibe/Mac/Settings/SettingsGeneralViewController.m`)

`NSSwitch *_reopenPlaylistSwitch` from `switchWithAction:@selector(toggleReopenPlaylist:)`; a new **Startup** section placed second, below Audio (`sectionWithHeader:STR_SETTINGS_STARTUP_SECTION rows:` with `[SettingsRowView rowWithTitle:STR_SETTINGS_REOPEN_PLAYLIST caption:STR_SETTINGS_REOPEN_PLAYLIST_CAPTION control:_reopenPlaylistSwitch]` — that helper's first caller); state read in `refreshFromSettings`; the action writes the setting then `applySettingsLiveEffects:VibeSettingsLiveEffectReopenLastPlaylist`, the same two-line shape as `toggleAlwaysOnTop:`. Panes share size, so re-run `dump_settings_ui` afterwards.

## Step 7 — strings and translations

`Vibe/Common/VibeStrings.h` beside `STR_SETTINGS_ALWAYS_ON_TOP` (`:228`):

```objc
#define STR_SETTINGS_STARTUP_SECTION         NSLS(@"settings.general.startup_section",         @"Startup",              @"Settings, General pane: heading above the launch-behavior rows.")
#define STR_SETTINGS_REOPEN_PLAYLIST         NSLS(@"settings.general.reopen_playlist",         @"Reopen last playlist", @"Settings, General pane, Startup group: switch that brings the previous session's playlist back when the app launches, paused. Sentence case, like the other switches.")
#define STR_SETTINGS_REOPEN_PLAYLIST_CAPTION NSLS(@"settings.general.reopen_playlist.caption", @"The tracks come back in order. Playback does not start on its own.", @"Settings, General pane: caption under the 'Reopen last playlist' switch. Two short sentences: the list is restored as it was, and nothing plays until the user presses play.")
```

Then `make strings`, translate all three keys into every catalog language (read the list from `Resources/Localizable.xcstrings`; the `vibe-strings` skill has the conventions), `make check-strings`, `make check-translations`.

## Step 8 — debug surface

- `Vibe/Debug/Mac/DebugCommandTable.m`: `set_reopen_playlist <on|off>` beside `set_pause_at_track_end` (writes the setting, requests the effect, replies `{ok, reopenLastPlaylist}`); `dump_last_playlist` beside `save_playlist` replying `{exists, rows, currentPath}` from the file (a separate verb, since stress runs poll `dump_state`).
- `Vibe/Debug/Mac/Introspection/MainPlayerController+Debug.h`: `debugLastPlaylistDictionary` and `debugNowPlayingWithheldForRestore`, implemented in `MainPlayerController.m`'s existing `#if DEBUG` block so the path function and key keep one spelling.
- `Vibe/Debug/Mac/DebugStateDump.m`: `settings.reopenLastPlaylist`; `ui.nowPlayingWithheldForRestore`.
- `.claude/skills/vibe-debug/SKILL.md`: the two verbs' lines.

## Step 9 — docs

- **Root `CLAUDE.md`: no new guarantee.** The root's own rule — a rule with a single call site belongs in its directory's doc — applies: the outranking is one `if` in `AppDelegate`, and no-autoplay/no-publish is one flag whose touch points are all under `Mac/MainWindow/`.
- `Vibe/Mac/MainWindow/CLAUDE.md`: reword the Save Playlist paragraph (`writePlaylistToURL:error:` is the one write path *for a user-chosen file*; the quit-time mirror is the writer's second caller — absolute, container, never Open Recent); a short "The last playlist" section (restore = the removal funnel's park through `loadURLs:selectingIndex:startPaused:`, the withheld flag and its two clearing sites and why not `playWillStartHandler`, the hold sync in `updateUI` and its balance with AppStats'); extend the Now Playing sentence.
- `Vibe/Mac/App/CLAUDE.md`: one paragraph beside "Stats": grants → drain → restore → empty state, the restore is not an open, the quit-time call and why the hold exists.
- `Vibe/Mac/Settings/CLAUDE.md`: the Startup row; Factory Reset covers it through `All`.
- `Vibe/Playlist/CLAUDE.md`: `fileURLsInM3UData:` as the reader for the app's own output; "the writer's callers are File > Save Playlist… and the quit-time mirror". `Vibe/Playlist/Mac/CLAUDE.md`: `play:` → `loadURLs:selectingIndex:`.
- `Vibe/Common/CLAUDE.md` AppStats paragraph: one clause that the mac shell's last-playlist hold shares the counter and balances its own pair.
- README (after the drag-out line): "Settings > General > Reopen last playlist brings the playlist back at the next launch, paused on the last track. Off by default." CHANGELOG under `# v1.12`.
- This file moves to `docs/done/` when the feature lands, with a header in `docs/done/playlist-row-removal.md`'s shape.

## Tests (`make test`)

`Tests/PlaylistFileTests.m`, beside the writer tests, with the existing `TrackAt`/`TaggedTrackAt` helpers:
- `testM3UDataWrittenAbsoluteReadsBackThroughFileURLsInM3UData` — plain, subfolder, `#`-named, edge-whitespace, newline and non-ASCII names; `m3uTextForTracks:relativeToDirectory:nil` → UTF-8 → `fileURLsInM3UData:` → the same paths in order (the URL-form entries are the point).
- `testFileURLsInM3UDataSkipsRelativeAndDirectiveLines` — `#EXTM3U`, `#EXTINF`, a relative entry, a `file://` entry, an absolute entry → the two absolute paths.
- `testFileURLsInM3UDataOfEmptyDataIsEmpty`.

`Tests/OpenBurstCoalescerTests.m`: extend the empty-start test so a later `openBurstURLs:` drains once with `append == NO`. The model, the display rules and `PlaylistTests` are untouched.

## Verification (`vibe-debug`, Debug build)

`launch.sh` quits a running instance through `quit`, which runs `applicationWillTerminate:`, so it is both the quit and the relaunch.

```bash
V=build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe; APP="$PWD/build/DerivedData/Build/Products/Debug/Vibe.app"
L=.claude/skills/vibe-debug/scripts/launch.sh

# Ordinary restore. VIBE_AUDIBLE=1, or dump_now_playing is vacuous under --no-audio-hw.
VIBE_AUDIBLE=1 $L
"$V" --debug-cmd set_reopen_playlist on
"$V" --debug-cmd open Assets/test_audio_files          # poll dump_state until playlist.count > 0
"$V" --debug-cmd play_index 2
"$V" --debug-cmd dump_last_playlist                    # {exists:false} — nothing is written before quit
VIBE_AUDIBLE=1 $L                                      # quit + relaunch
"$V" --debug-cmd dump_state | jq '{count:.playlist.count, index:.playlist.currentIndex, state:.player.state,
    cur:.ui.currentTime, total:.ui.totalTime, display:.ui.displayState, held:.ui.nowPlayingWithheldForRestore}'
#   → N, 2, "paused", "0:00", the real length, "track", true
"$V" --debug-cmd dump_now_playing | jq .hasInfo       # 0
"$V" --debug-cmd dump_last_playlist                    # {exists:true, rows:N, currentPath:…row 2}
"$V" --debug-cmd check_consistency                     # clean
"$V" --debug-cmd play_pause; "$V" --debug-cmd dump_state | jq '.player.state, .ui.nowPlayingWithheldForRestore'   # "playing", false
"$V" --debug-cmd dump_now_playing | jq .hasInfo       # 1
# Double-click path: restore again, then play_index 0 → didStartPlaying: clears the flag, hasInfo 1.

# Launch-time open outranks
VIBE_AUDIBLE=1 $L Assets/test_audio_files/tone-short-1.wav
"$V" --debug-cmd dump_state | jq '.playlist.count, .player.state'   # 1, "playing"
"$V" --debug-cmd dump_last_playlist | jq .rows        # still N until the next quit

# Empty at quit → empty at launch, mirror deleted
open -a "$APP"; "$V" --debug-cmd click_menu menu_close; $L
"$V" --debug-cmd dump_state | jq .playlist.count; "$V" --debug-cmd dump_last_playlist | jq .exists   # 0, false

# Setting off deletes the file now, not at quit
"$V" --debug-cmd open Assets/test_audio_files; $L; "$V" --debug-cmd dump_last_playlist | jq .exists   # true
"$V" --debug-cmd set_reopen_playlist off; "$V" --debug-cmd dump_last_playlist | jq .exists           # false
$L; "$V" --debug-cmd dump_state | jq .playlist.count   # 0

# Settings pane, asserting the setting rather than the control
"$V" --debug-cmd settings_open general; "$V" --debug-cmd dump_settings_ui | jq -c '.controls[]|{name,kind}'
"$V" --debug-cmd settings_click "Load last playlist on launch" on; "$V" --debug-cmd dump_state | jq .settings.reopenLastPlaylist   # true
# Factory reset: settings_open advanced → settings_click the reset → dump_last_playlist.exists false, setting false

# kill -9 loses the session (accepted): the mirror is the LAST QUIT's
"$V" --debug-cmd set_reopen_playlist on; "$V" --debug-cmd open Assets/test_audio_files; $L   # mirror = A
"$V" --debug-cmd open <another folder>; kill -9 "$(pgrep -x Vibe)"; $L
"$V" --debug-cmd dump_state | jq .playlist.count      # A's count

# Sudden termination, by hand once: setting on, playlist loaded, paused, ⌘Q → the mirror exists afterwards.
# Cloud current track: set_fake_cloud cannot arm before launch, and the restore's submission is the
# removal funnel's parked open byte for byte — verify with play_index onto a fake-cloud row and
# dump_row_loading, or once with a genuinely evicted iCloud Drive file.
```

Gates: `make test`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`, `make strings && make check-strings`, `make check-translations`, `make build-ios` (the new `PlaylistFile` method is shared, Foundation-only).

## Budget, stated

- **New files: 0. New types: 0** (one bit on the existing effect enum).
- **Net lines**: about +240 code (`PlaylistFile` +20, `PlaylistController` +11 net of the deleted `play:`, settings +25, controller ≈ +90 across the `.m`, the two headers, `+NowPlaying` and `+PlayerEvents`, `AppDelegate` +5, Settings pane +12, strings +3, debug ≈ +30), +40 tests, ≈ +30 docs, plus the catalog entries.
- **Deleted or unified**: `PlaylistController.play:` deleted; `MainPlayerController.play:` and the restore unified into one replacement path so the launch grace, `cancelScan` and the deferred load are spelled once; `rowWithTitle:caption:control:` gains its first caller; the earlier design's `LastPlaylistStore`, `LastPlaylistRules.h`, `+Debug` header, rules tests, sixth display state and four verbs are replaced by two verbs and two flags.
